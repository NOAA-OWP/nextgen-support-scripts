import filecmp
import glob
import os
import re
import shutil
import subprocess
import sys
from abc import ABC, abstractmethod
from datetime import datetime, timedelta


class DAPreprocessor(ABC):
    """Abstract base for one cycle of streamflow/reservoir DA pre-processing.

    Converts the raw observations downloaded by JNWM_FETCH_FLOW_DA_OBSERVATIONS
    into the NetCDF timeslice/timeseries files the NWM data assimilation reads.
    Concrete subclasses wrap the nwm-data-assimilation tools for one case type:
    :class:`USACEPreprocessor`, :class:`RFCPreprocessor` and
    :class:`USGSandCAPreprocessor` (which runs USGS, Env. Canada and the merge of
    the two in a single pass).

    Every subclass drives the same four steps, in this order:

    1. ``copy_raw_data``        - DCOMROOT raw downloads -> working_dir/rawdatafiles
    2. ``copy_existing_files``  - previously created products -> working_dir/timeslices
    3. ``execute``              - run the make_*.py tool(s) over the raw data
    4. ``move_outputs_to_storage`` - working_dir/timeslices -> COMOUT/<product dir>

    Step 2 is not optional: the make_*.py tools merge new observations *into* an
    existing product file of the same timestamp if one is present in their output
    directory, so the previous cycles' files have to be staged there first.

    This replaces the v3.0.6 ex-scripts exnwm_usgs_timeslices.sh,
    exnwm_canada_timeslices.sh, exnwm_ace_timeslices.sh, exnwm_rfc_timeseries.sh
    and exnwm_merge_usgs_ca_timeslices.sh together with their nwmcopy.sh helpers.
    """

    # Case types. USGS and Env. Canada form a single case: they are processed
    # together so their timeslices can be merged in the same pass (in v3.0.6 this
    # took three separate jobs).
    CASE_USGS_N_ENVCA = "USGS_N_ENVCA"
    CASE_USACE = "USACE"
    CASE_RFC = "RFC"

    CASE_TYPES = (CASE_USGS_N_ENVCA, CASE_USACE, CASE_RFC)

    # COMOUT subdirectories the products are stored in
    COM_SUBDIR_USGS = "usgs_timeslices"
    COM_SUBDIR_ENVCA = "canada_timeslices"
    COM_SUBDIR_MERGED = "merged_usgs_and_ca_timeslices"
    COM_SUBDIR_USACE = "usace_timeslices"
    COM_SUBDIR_RFC = "rfc_timeseries"

    # DCOMROOT/<PDY> subdirectories the raw downloads land in (written by
    # scripts/exnwm_fetch_flow_da_observations.sh)
    DCOM_SUBDIR_USGS = os.path.join("obs", "raw", "water_level", "usgs_streamflow")
    DCOM_SUBDIR_ENVCA = "can_streamgauge"
    DCOM_SUBDIR_USACE = "usace_streamflow"
    DCOM_SUBDIR_RFC = "rfc_reservoir"

    # Product filename suffixes, as written by the make_*.py tools. Note the
    # leading dot used when globbing: "*.usgsTimeSlice.ncdf" does not match the
    # merged "*.causgsTimeSlice.ncdf" files sitting in the same directory.
    SUFFIX_USGS = "usgsTimeSlice.ncdf"
    SUFFIX_ENVCA = "wscTimeSlice.ncdf"
    SUFFIX_MERGED = "causgsTimeSlice.ncdf"
    SUFFIX_USACE = "usaceTimeSlice.ncdf"
    SUFFIX_RFC = "RFCTimeSeries.ncdf"

    # How many cycles of already-created products are recycled through the tools
    # (the $NDATE -4 window of the v3 nwm_copy/nwm_postcopy functions)
    LOOKBACK_CYCLES = 4

    # Leading YYYY-MM-DD_HH of a product filename, e.g.
    #   2026-07-21_12:00:00.15min.usgsTimeSlice.ncdf  (USGS/USACE)
    #   2026-07-21_12_00_00.15min.wscTimeSlice.ncdf   (Env. Canada)
    #   2026-07-21_12.60min.CHNK1.RFCTimeSeries.ncdf  (RFC)
    _STAMP_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})_(\d{2})")

    def __init__(self, case_type: str, pdy: str, cyc: str, working_dir: str,
                 comout: str, precomout: str, dcomroot: str, package_dir: str):
        if case_type not in self.CASE_TYPES:
            raise ValueError(f"Unknown case_type: {case_type}")
        if not re.fullmatch(r"\d{8}", pdy):
            raise ValueError(f"PDY must be YYYYMMDD, got: {pdy!r}")
        if not re.fullmatch(r"\d{2}", cyc) or not 0 <= int(cyc) <= 23:
            raise ValueError(f"CYC must be 00-23, got: {cyc!r}")

        self.case_type = case_type
        self.pdy = pdy
        self.cyc = cyc
        self.working_dir = working_dir
        self.comout = comout
        self.precomout = precomout
        self.dcomroot = dcomroot
        # Root of the installed nwm.vX package; the make_*.py tools are looked up
        # underneath it (ush/nwm-data-assimilation/...).
        self.package_dir = package_dir

        os.makedirs(self.output_dir, exist_ok=True)

    # ------------------------------------------------------------------ #
    # Factory
    # ------------------------------------------------------------------ #

    @classmethod
    def create(cls, case_type: str, pdy: str, cyc: str, working_dir: str,
               comout: str, precomout: str, dcomroot: str,
               package_dir: str) -> "DAPreprocessor":
        """Build the concrete DAPreprocessor for case_type."""
        # Deferred imports to avoid a circular dependency (subclasses import this
        # module for the base class).
        from rfc_preprocessor import RFCPreprocessor
        from usace_preprocessor import USACEPreprocessor
        from usgs_and_ca_preprocessor import USGSandCAPreprocessor

        if case_type == cls.CASE_USGS_N_ENVCA:
            subcls = USGSandCAPreprocessor
        elif case_type == cls.CASE_USACE:
            subcls = USACEPreprocessor
        elif case_type == cls.CASE_RFC:
            subcls = RFCPreprocessor
        else:
            raise ValueError(f"No DAPreprocessor subclass for case_type: {case_type}")

        return subcls(
            case_type=case_type,
            pdy=pdy,
            cyc=cyc,
            working_dir=working_dir,
            comout=comout,
            precomout=precomout,
            dcomroot=dcomroot,
            package_dir=package_dir,
        )

    # ------------------------------------------------------------------ #
    # Cycle time helpers
    # ------------------------------------------------------------------ #

    @property
    def t0(self) -> datetime:
        """Valid time of the cycle being processed (PDY at CYC)."""
        return datetime.strptime(f"{self.pdy}{self.cyc}", "%Y%m%d%H")

    @property
    def pdym1(self) -> str:
        """PDY of the previous day, the date PRECOMOUT is stamped with."""
        return (self.t0 - timedelta(days=1)).strftime("%Y%m%d")

    @property
    def lookback_stamp(self) -> int:
        """T0 - LOOKBACK_CYCLES hours as YYYYMMDDHH, the cutoff a product's own
        timestamp is compared against ($NDATE -4 in the v3 scripts)."""
        return int((self.t0 - timedelta(hours=self.LOOKBACK_CYCLES)).strftime("%Y%m%d%H"))

    @classmethod
    def _file_stamp(cls, path: str) -> int | None:
        """The YYYYMMDDHH a product filename is stamped with, or None when the
        name does not start with a recognizable timestamp."""
        m = cls._STAMP_RE.match(os.path.basename(path))
        if m is None:
            return None
        return int("".join(m.groups()))

    # ------------------------------------------------------------------ #
    # Derived paths
    # ------------------------------------------------------------------ #

    @property
    def da_engine_dir(self) -> str:
        """Root of the data assimilation tooling inside the package."""
        return os.path.join(self.package_dir, "ush", "nwm-data-assimilation",
                            "data_assimilation_engine")

    @property
    def streamflow_dir(self) -> str:
        return os.path.join(self.da_engine_dir, "Streamflow_Scripts")

    @property
    def raw_dir(self) -> str:
        """Where copy_raw_data stages the DCOMROOT downloads."""
        return os.path.join(self.working_dir, "rawdatafiles")

    @property
    def output_dir(self) -> str:
        """Where the tools write their products, and where copy_existing_files
        stages the previous cycles' products for them to merge into."""
        return os.path.join(self.working_dir, "timeslices")

    def dcom_dir(self, dcom_subdir: str) -> str:
        """The raw-data directory a source's downloads land in for this PDY."""
        return os.path.join(self.dcomroot, self.pdy, dcom_subdir)

    def com_for_day(self, day: str) -> str | None:
        """The COM directory holding products stamped with `day` (YYYYMMDD).

        COMOUT for today and PRECOMOUT for yesterday. Older days -- needed only by
        RFC, which recycles three days of time series -- are derived by
        substituting the date stamp in COMOUT's basename (.../nwm.20260721 ->
        .../nwm.20260718); returns None when COMOUT carries no such stamp.
        """
        if day == self.pdy:
            return self.comout
        if day == self.pdym1:
            return self.precomout
        head, tail = os.path.split(self.comout.rstrip("/"))
        if self.pdy in tail:
            return os.path.join(head, tail.replace(self.pdy, day))
        return None

    # ------------------------------------------------------------------ #
    # Copy helpers
    # ------------------------------------------------------------------ #

    @staticmethod
    def _copy_one(src: str, dst_dir: str) -> int:
        """Copy a single file into dst_dir; return 0 on success, 1 on failure."""
        try:
            shutil.copy2(src, os.path.join(dst_dir, os.path.basename(src)))
        except OSError as e:
            print(f"ERROR: Could not copy {src} -> {dst_dir}: {e}", flush=True)
            return 1
        return 0

    def _copy_raw_files(self, src_dir: str, dst_dir: str) -> int:
        """Stage every regular file of a DCOMROOT raw-data directory into dst_dir.

        A missing or empty source is only a warning: the make_*.py tools treat an
        empty input directory as a no-op (they log a warning and exit 0), which is
        the behaviour the v3 ex-scripts relied on when a download was late.
        """
        os.makedirs(dst_dir, exist_ok=True)
        if not os.path.isdir(src_dir):
            print(f"WARNING: Raw data directory does not exist: {src_dir}", flush=True)
            return 0

        rc = 0
        count = 0
        for name in sorted(os.listdir(src_dir)):
            src = os.path.join(src_dir, name)
            if not os.path.isfile(src):
                continue
            rc |= self._copy_one(src, dst_dir)
            count += 1

        if count == 0:
            print(f"WARNING: No raw data files in {src_dir}", flush=True)
        else:
            print(f"INFO: Staged {count} raw file(s) from {src_dir} -> {dst_dir}", flush=True)
        return rc

    def _copy_products(self, src_dir: str, suffix: str, recent_only: bool = True) -> int:
        """Stage previously created *.<suffix> products from src_dir into
        output_dir so the tools merge this cycle's observations into them.

        With recent_only, products stamped earlier than LOOKBACK_CYCLES hours
        before T0 are skipped. A missing src_dir is a warning, not an error: on
        the first cycle after an install there is nothing to recycle yet.
        """
        if not os.path.isdir(src_dir):
            print(f"WARNING: Product directory does not exist: {src_dir}", flush=True)
            return 0

        rc = 0
        count = 0
        for src in sorted(glob.glob(os.path.join(src_dir, f"*.{suffix}"))):
            if not os.path.isfile(src):
                continue
            if recent_only:
                stamp = self._file_stamp(src)
                if stamp is None:
                    print(f"WARNING: Unrecognized product filename, skipped: {src}", flush=True)
                    continue
                if stamp < self.lookback_stamp:
                    continue
            rc |= self._copy_one(src, self.output_dir)
            count += 1

        print(f"INFO: Staged {count} existing *.{suffix} file(s) from {src_dir}", flush=True)
        return rc

    def _copy_existing_products(self, com_subdir: str, suffix: str) -> int:
        """nwm_copy: recycle the last LOOKBACK_CYCLES cycles of a product from
        COMOUT, plus PRECOMOUT when the window reaches back into yesterday."""
        rc = self._copy_products(os.path.join(self.comout, com_subdir), suffix)
        if int(self.cyc) <= self.LOOKBACK_CYCLES:
            rc |= self._copy_products(os.path.join(self.precomout, com_subdir), suffix)
        return rc

    # ------------------------------------------------------------------ #
    # Output staging
    # ------------------------------------------------------------------ #

    def _store_outputs(self, suffix: str, com_subdir: str,
                       recent_only: bool = True) -> int:
        """nwm_postcopy: publish output_dir/*.<suffix> to <COM>/<com_subdir>.

        Each product goes to the COM directory of the day it is stamped with, not
        necessarily this cycle's COMOUT -- at cycles 00-03 the window still
        produces files belonging to yesterday. Products whose content is unchanged
        from what is already stored are left alone.
        """
        rc = 0
        stored = 0
        for src in sorted(glob.glob(os.path.join(self.output_dir, f"*.{suffix}"))):
            stamp = self._file_stamp(src)
            if stamp is None:
                print(f"WARNING: Unrecognized product filename, not stored: {src}", flush=True)
                continue
            if recent_only and stamp < self.lookback_stamp:
                continue

            com = self.com_for_day(str(stamp)[:8])
            if com is None:
                print(f"WARNING: No COM directory for {src}; not stored", flush=True)
                rc |= 1
                continue

            dst_dir = os.path.join(com, com_subdir)
            os.makedirs(dst_dir, exist_ok=True)
            dst = os.path.join(dst_dir, os.path.basename(src))
            if os.path.isfile(dst) and filecmp.cmp(src, dst, shallow=False):
                continue

            rc |= self._copy_one(src, dst_dir)
            stored += 1

        print(f"INFO: Stored {stored} *.{suffix} file(s) under {com_subdir}", flush=True)
        return rc

    # ------------------------------------------------------------------ #
    # Tool execution
    # ------------------------------------------------------------------ #

    @property
    def python(self) -> str:
        """Interpreter the make_*.py tools are run with.

        Defaults to the one running this driver, overridable through $DA_PYTHON:
        the tools need the data_assimilation_engine dependencies (netCDF4, numpy),
        which the ecFlow testbed venv does not carry, so the two may well live in
        different environments.
        """
        return os.environ.get("DA_PYTHON", sys.executable)

    def _run_tool(self, script: str, args: list) -> int:
        """Run one of the nwm-data-assimilation make_*.py tools.

        The tools import their helper modules from their own directory, which
        Python puts on sys.path for us, so they can be run by absolute path. They
        exit 0 (with a logged warning) when there is nothing to process, and
        non-zero only on a real failure.
        """
        if not os.path.isfile(script):
            print(f"ERROR: Preprocessing tool not found: {script}", flush=True)
            return 1

        my_env = os.environ.copy()
        if "PYTHONPATH" in my_env:
           my_env["PYTHONPATH"] = f"{self.package_dir}/ush/nwm-data-assimilation:" + \
                      my_env["PYTHONPATH"]
        else:
           my_env["PYTHONPATH"] = f"{self.package_dir}/ush/nwm-data-assimilation"

        cmd = [self.python, script] + [str(a) for a in args]
        print(f"INFO: Running {' '.join(cmd)}", flush=True)
        rc = subprocess.run(cmd, cwd=self.working_dir, env=my_env).returncode
        if rc != 0:
            print(f"ERROR: {os.path.basename(script)} exited with return code {rc}", flush=True)
        return rc

    # ------------------------------------------------------------------ #
    # Steps (implemented per case type)
    # ------------------------------------------------------------------ #

    @abstractmethod
    def copy_raw_data(self) -> int:
        """Stage this case's raw downloads from DCOMROOT into working_dir.
        Return 0 on success, non-zero on a copy failure."""

    @abstractmethod
    def copy_existing_files(self) -> int:
        """Stage the products of the previous LOOKBACK_CYCLES cycles from COMOUT
        (and PRECOMOUT once the window crosses midnight) into output_dir, so the
        tools merge this cycle's observations into them instead of replacing
        them. Return 0 on success, non-zero on a copy failure."""

    @abstractmethod
    def execute(self) -> int:
        """Run the make_*.py tool(s) that turn the staged raw data into timeslice
        or timeseries files in output_dir. Return the tool exit code."""

    @abstractmethod
    def move_outputs_to_storage(self) -> int:
        """Publish the products from output_dir to their COMOUT directories.
        Return 0 on success, non-zero if a file could not be stored."""

    # ------------------------------------------------------------------ #
    # Driver
    # ------------------------------------------------------------------ #

    def run(self) -> int:
        """Run the four steps in order, stopping at the first failure."""
        for step in (self.copy_raw_data, self.copy_existing_files,
                     self.execute, self.move_outputs_to_storage):
            print(f"INFO: {self.case_type} {self.pdy}{self.cyc}: {step.__name__}", flush=True)
            rc = step()
            if rc != 0:
                print(f"ERROR: {step.__name__} failed with return code {rc}", flush=True)
                return rc
        return 0
