import json
import os
import threading

from ecf_task_mgr.ecf_interface import EcflowConnection, EcflowInterface
from ecf_task_mgr.tasks import Task

from nwm_forecast import NWMForecast
from nwm_region import NWMRegion


class _CorePool:
    """A core-ID allocator handing out disjoint sets of physical core indices.

    Constructed from an explicit list of core IDs (e.g. the cores the job was
    actually granted on a shared node); IDs need not be contiguous or start at 0.
    ``acquire(n)`` blocks until ``n`` cores are free (``n`` is clamped to the pool
    size so an oversized request can't deadlock), removes them from the free set,
    and returns the list of core IDs; pass that same list to ``release``. Because
    a core ID is removed from the free set on acquire and only added back on
    release, no core is ever held by two regions at once — suitable for docker
    ``--cpuset-cpus`` pinning.
    """

    def __init__(self, cores):
        # Dedup while preserving the given order; fall back to a single core.
        self._all = list(dict.fromkeys(int(c) for c in cores)) or [0]
        self.total = len(self._all)
        self._free = set(self._all)
        self._cond = threading.Condition()

    def acquire(self, n: int) -> list:
        n = max(1, min(int(n), self.total))
        with self._cond:
            while len(self._free) < n:
                self._cond.wait()
            ids = sorted(self._free)[:n]
            self._free.difference_update(ids)
        return ids

    def release(self, ids: list) -> None:
        with self._cond:
            self._free.update(ids)
            self._cond.notify_all()


class NWMRunner:
    """Drives one or more NWM runs, one per region, in parallel.

    Holds a mapping of :class:`NWMRegion` -> :class:`NWMForecast` and records
    per-region outcomes in a JSON status file (``job_status.json``) in the shared
    working directory (statuses "succeed"/"failed"/"unknown"; Extended AnA entries
    also carry ``pass1``/``pass2``).

    Regions are independent and run concurrently, scheduled by a core budget:
    each forecast's ``nprocs`` cores are drawn from a pool of core IDs (``cores``,
    default ``range(os.cpu_count())``; pass an explicit list to restrict to a
    granted allocation) and pinned to that region's containers via
    ``--cpuset-cpus``. No core is used by two regions at once, and at most
    ``len(cores)`` cores are in use. Container-environment setup is done serially
    up front so the shared ``run.sh`` is stable and read-only during the parallel
    phase.

    Restart handling still uses the ecFlow ``PRE_WORKDIR`` variable (NONE = new
    run; else the failed job's working dir). On a restart ``run()`` reads that
    job's status file and, per region, skips ones that already succeeded and
    resumes failed ones via ``runRTE_restart`` (pass number from the recorded
    pass statuses).
    """

    STATUS_FILE = "job_status.json"

    def __init__(self, jobs: dict[NWMRegion, NWMForecast] | None = None,
                 cores: list | None = None):
        self.jobs: dict[NWMRegion, NWMForecast] = dict(jobs) if jobs else {}
        # Core IDs available to the scheduler. Default to all logical cores
        # (0..cpu_count-1); pass an explicit list to restrict to the cores this
        # job was actually granted on a shared node.
        self.cores = list(cores) if cores is not None else list(range(os.cpu_count() or 1))
        self._status_lock = threading.Lock()
        self._overall_rc = 0

    def add(self, region: NWMRegion, forecast: NWMForecast) -> None:
        """Register (or replace) the forecast to run for a region."""
        self.jobs[region] = forecast

    # ------------------------------------------------------------------ #
    # Status file helpers
    # ------------------------------------------------------------------ #

    @staticmethod
    def _is_ext_ana(fcst: NWMForecast) -> bool:
        return fcst.case_type == "CONUS_EXT_ANALYSIS_ASSIM"

    def _init_status(self) -> dict:
        """Build the initial status mapping (every region "unknown", with
        pass1/pass2 "unknown" for Extended AnA)."""
        status = {}
        for region, fcst in self.jobs.items():
            entry = {"status": "unknown"}
            if self._is_ext_ana(fcst):
                entry["pass1"] = "unknown"
                entry["pass2"] = "unknown"
            status[region.id] = entry
        return status

    @staticmethod
    def _write_status(path: str, status: dict) -> None:
        with open(path, "w") as f:
            json.dump(status, f, indent=2)

    @staticmethod
    def _load_status(path: str) -> dict:
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            print(f"WARNING: could not read job status file {path}: {e}", flush=True)
            return {}

    @staticmethod
    def _failed_pass(entry: dict) -> int:
        """Pass number to resume from for a failed Extended AnA region: pass 1 if
        pass 1 failed, else pass 2."""
        if entry.get("pass1") == "failed":
            return 1
        if entry.get("pass2") == "failed":
            return 2
        return 1

    def _record(self, status: dict, status_path: str, region: NWMRegion,
                fcst: NWMForecast, rc: int) -> None:
        """Thread-safe: record a region's outcome and rewrite the status file."""
        with self._status_lock:
            status[region.id]["status"] = "succeed" if rc == 0 else "failed"
            if self._is_ext_ana(fcst):
                status[region.id]["pass1"] = fcst.pass1_status or "unknown"
                status[region.id]["pass2"] = fcst.pass2_status or "unknown"
            region.jobstatus = status[region.id]["status"]
            if rc != 0:
                self._overall_rc = rc
            self._write_status(status_path, status)

    # ------------------------------------------------------------------ #
    # Per-region worker (runs in its own thread, gated by the proc pool)
    # ------------------------------------------------------------------ #

    def _run_region(self, region: NWMRegion, fcst: NWMForecast, prev: dict,
                    is_restart: bool, previous_workdir: str,
                    pool: _CorePool, status: dict, status_path: str) -> None:
        cores = pool.acquire(fcst.nprocs)
        # Pin this region's containers to the assigned cores (docker --cpuset-cpus).
        fcst.cpuset = ",".join(str(c) for c in cores)
        try:
            print(
                f"===> Region {region.id} ({region.case_type}): pinned to core(s) "
                f"[{fcst.cpuset}]; config={fcst.config_name} T0={fcst.t0}",
                flush=True,
            )
            if is_restart and prev.get("status") == "failed":
                pass_num = self._failed_pass(prev)
                print(f"===> Region {region.id}: previously failed — restarting at pass {pass_num}.", flush=True)
                rc = fcst.runRTE_restart(previous_workdir, pass_num)
            else:
                rc = fcst.runRTE()

            if rc == 0:
                rc = fcst.move_outputs_to_storage()
                if rc != 0:
                    print(
                        f"ERROR: move_outputs_to_storage for region {region.id} "
                        f"exited with return code {rc}",
                        flush=True,
                    )
        except Exception as e:
            print(f"ERROR: region {region.id} raised: {e}", flush=True)
            rc = 1
        finally:
            pool.release(cores)
            fcst.cpuset = ""

        self._record(status, status_path, region, fcst, rc)

    # ------------------------------------------------------------------ #
    # Run
    # ------------------------------------------------------------------ #

    def run(self) -> int:
        """Configure and run every region's forecast in parallel (bounded by the
        processor budget), tracking per-region status in the job status file.
        Returns a nonzero exit code if any region failed, else 0."""
        if not self.jobs:
            return 0

        self._overall_rc = 0
        package_dir = next(iter(self.jobs.values())).package_dir
        ecfcon = EcflowConnection( f"{package_dir}/ush/nwm-realtime/ecflow-settings.json" )
        is_restart = NWMForecast._is_restart(ecfcon)
        previous_workdir = NWMForecast._pre_workdir(ecfcon)

        # All forecasts share the same working directory.
        working_dir = next(iter(self.jobs.values())).working_dir
        status_path = os.path.join(working_dir, self.STATUS_FILE)

        print(f"if_restart : {is_restart}")
        print(f"previous_workdir : {previous_workdir}")

        prev_status = {}
        if is_restart and previous_workdir and previous_workdir != "NONE":
            prev_status = self._load_status(
                os.path.join(previous_workdir, self.STATUS_FILE)
            )

        status = self._init_status()
        self._write_status(status_path, status)

        # Partition regions: on a restart, ones that already succeeded are carried
        # forward and skipped; everything else is queued to run.
        to_run = []
        for region, fcst in self.jobs.items():
            prev = prev_status.get(region.id, {})
            if is_restart and prev.get("status") == "succeed":
                print(f"===> Region {region.id}: previously succeeded — skipping.", flush=True)
                status[region.id]["status"] = "succeed"
                if self._is_ext_ana(fcst):
                    status[region.id]["pass1"] = prev.get("pass1", "succeed")
                    status[region.id]["pass2"] = prev.get("pass2", "succeed")
                region.jobstatus = "succeed"
            else:
                to_run.append((region, fcst, prev))
        self._write_status(status_path, status)

        # Phase 1 (serial): container-env + warm-state staging. configureRTE
        # rewrites the shared run.sh/config.bashrc with identical content, so doing
        # it serially leaves a stable file for the parallel phase to source.
        configured = []
        for region, fcst, prev in to_run:
            try:
                fcst.configureRTE()
                configured.append((region, fcst, prev))
            except Exception as e:
                print(f"ERROR: configureRTE failed for region {region.id}: {e}", flush=True)
                with self._status_lock:
                    status[region.id]["status"] = "failed"
                    region.jobstatus = "failed"
                    self._overall_rc = 1
                    self._write_status(status_path, status)

        # For a restart, add the failed-workdir bind mount to run.sh ONCE (it is
        # identical for every region), so parallel restarts don't race on run.sh.
        if is_restart and previous_workdir and previous_workdir != "NONE" and configured:
            configured[0][1]._mount_failed_workdir(previous_workdir)

        # Phase 2 (parallel): one thread per region, each pinned to a disjoint set
        # of cores drawn from the core pool.
        pool = _CorePool(self.cores)
        print(
            f"Running {len(configured)} region(s) in parallel; "
            f"{len(self.cores)} core(s) available: {self.cores}",
            flush=True,
        )
        threads = []
        for region, fcst, prev in configured:
            t = threading.Thread(
                target=self._run_region,
                args=(region, fcst, prev, is_restart, previous_workdir,
                      pool, status, status_path),
                name=f"region-{region.id}",
            )
            t.start()
            threads.append(t)
        for t in threads:
            t.join()

        # Restart pointer: clear it when everything succeeded, else point the next
        # run at this job's working directory.
        if self._overall_rc == 0:
            NWMForecast._set_ecf_var(ecfcon, "PRE_WORKDIR", "NONE")
        else:
            NWMForecast._set_ecf_var(ecfcon, "PRE_WORKDIR", working_dir)

        return self._overall_rc
