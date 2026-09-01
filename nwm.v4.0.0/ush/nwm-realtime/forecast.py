import os
from datetime import timedelta

from nwm_forecast import NWMForecast

class Forecast(NWMForecast):
    """Forward forecast configurations (Short Range, Medium Range). A single RTE
    run seeded from the matching AnA warm state."""

    def _short_range_state_save_src(self) -> str:
        """Return the source state_save path for CONUS_SHORT_RANGE warm start.
        Uses the AnA state_save valid at T0 (the second AnA run of the same cycle)
        on the current day (comout/{cyc}/CONUS_ANALYSIS_ASSIM/state_save_<T0 %Y%m%d%H>).
        The caller is responsible for checking whether the returned path exists;
        if it does not, a cold start should be used."""
        cyc = self.t0.strftime("%H")
        ts = self.t0.strftime("%Y%m%d%H")
        return os.path.join(self.comout, cyc, "CONUS_ANALYSIS_ASSIM", self.run_id, f"state_save_{ts}")

    # ------------------------------------------------------------------ #
    # Subclass-specific hooks used by NWMForecast.configureRTE
    # ------------------------------------------------------------------ #

    @property
    def _formulation_dir(self) -> str:
        return "default_short"

    def _state_save_src(self) -> str:
        return self._short_range_state_save_src()

    # ------------------------------------------------------------------ #
    # Restart
    # ------------------------------------------------------------------ #

    def forecast_restart(self) -> int:
        """Restart a failed Short Range forecast from a checkpoint."""
        paths = self._paths()
        src_dir = paths.failed_container_run_dir
        dst_dir = paths.container_run_dir
        checkpoint_dir = os.path.join(src_dir, "checkpoint")
        if self._is_empty_or_missing( checkpoint_dir ):
            rte_start_time = self.t0.strftime("%Y-%m-%d %H:%M:%S")
            src_state_save = self._short_range_state_save_src()
            # Container path where RTE writes/reads the saved model state
            # (the run directory inside the /ngwpc/run_ngen mount).
            state_save_dir = paths.container(f"{self.run_id}_state_save")
            src_state_save_tar = f"{src_state_save}.tar"
            if os.path.isfile(src_state_save_tar):
                print(
                    f"INFO: Warm states found at {src_state_save_tar}; "
                    f"T0={self.t0:%Y-%m-%d %H:%M:%S}; CONUS_SHORT_RANGE job will use warm states.",
                    flush=True,
                )
                load_state_arg = f' --load_state_from "{state_save_dir}"'
            else:
                print(
                    f"WARNING: Warm states could not be found at {src_state_save_tar}; "
                    f"T0={self.t0:%Y-%m-%d %H:%M:%S}; CONUS_SHORT_RANGE job cold started.",
                    flush=True,
                )
                load_state_arg = ""
            docker_args = (
                f'-n {self.nprocs} -fconfig "short_range" -dt "{rte_start_time}" -rname "default_short" -nwmout'
                f'{load_state_arg}{self.vpu_arg}{self.hydrofab_arg}{self.form_assign_arg}{self.cat_grp_arg}{self.output_format_arg} --checkpoint_interval 1'
            )
            working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
            if os.path.isdir( working_rfc_path ) and any(os.scandir(working_rfc_path)):
                docker_args += f' -rfc {os.path.join(paths.container_run_dir, "rfc_timeseries")}'
            else:
                print("WARNING: RFC Reservoir timeseries not found! Skipping reservoir data assimilation!")

            restart_rc = self._docker_run(docker_args)
        else:
            restart_rc = self._docker_restart( src_dir, dst_dir, checkpoint_dir )
        return restart_rc

    def _store_logs(self, run_dir: str, dst_logs: str) -> None:
        """Single un-archived run: the run dir's top-level *.log files plus the
        shared MSWM logs tree."""
        self._store_ngen_logs(run_dir, dst_logs)
        self._store_mswm_logs(dst_logs)

    def move_outputs_to_storage(self) -> int:
        """Store the single run's products: catchment output (stamped at T0) and
        T-route output (stamped at T0 + 1h)."""
        run_dir, dst, dst_logs = self._storage_dirs()
        self._store_logs(run_dir, dst_logs)

        rc = 0
        ts_t0 = self.t0.strftime("%Y%m%d%H")
        ts_sr = (self.t0 + timedelta(hours=1)).strftime("%Y%m%d%H")
        rc |= self._store_file(
            os.path.join(run_dir, "Output", "catchment_output.nc"),
            os.path.join(dst, f"catchment_output_{ts_t0}00.nc"),
        )
        rc |= self._store_file(
            os.path.join(run_dir, "Output", f"troute_output_{ts_t0}00.nc"),
            dst,
        )
        rc |= self._store_file(
            os.path.join(run_dir, "Output", f"troute_lakeout_{ts_t0}00.nc"),
            dst,
        )
        return rc

    # ------------------------------------------------------------------ #
    # Run entry points
    # ------------------------------------------------------------------ #

    def runRTE(self) -> int:
        case_type = self.case_type
        if case_type is None:
            raise NotImplementedError(
                f"runRTE not implemented for config='{self.config_name}', domain='{self.domain}'"
            )

        if case_type == "CONUS_SHORT_RANGE":
            paths = self._paths()
            rte_start_time = self.t0.strftime("%Y-%m-%d %H:%M:%S")
            src_state_save = self._short_range_state_save_src()
            # Container path where RTE writes/reads the saved model state
            # (the run directory inside the /ngwpc/run_ngen mount).
            state_save_dir = paths.container(f"{self.run_id}_state_save")
            src_state_save_tar = f"{src_state_save}.tar"
            if os.path.isfile(src_state_save_tar):
                print(
                    f"INFO: Warm states found at {src_state_save_tar}; "
                    f"T0={self.t0:%Y-%m-%d %H:%M:%S}; CONUS_SHORT_RANGE job will use warm states.",
                    flush=True,
                )
                load_state_arg = f' --load_state_from "{state_save_dir}"'
            else:
                print(
                    f"WARNING: Warm states could not be found at {src_state_save_tar}; "
                    f"T0={self.t0:%Y-%m-%d %H:%M:%S}; CONUS_SHORT_RANGE job cold started.",
                    flush=True,
                )
                load_state_arg = ""
            docker_args = (
                f'-n {self.nprocs} -fconfig "short_range" -dt "{rte_start_time}" -rname "default_short" -nwmout'
                f'{load_state_arg}{self.vpu_arg}{self.hydrofab_arg}{self.form_assign_arg}{self.cat_grp_arg}{self.output_format_arg} --checkpoint_interval 1'
            )
            working_rfc_path = os.path.join(paths.host_run_dir, "rfc_timeseries")
            if os.path.isdir( working_rfc_path ) and any(os.scandir(working_rfc_path)):
                docker_args += f' -rfc {os.path.join(paths.container_run_dir, "rfc_timeseries")}'
            else:
                print("WARNING: RFC Reservoir timeseries not found! Skipping reservoir data assimilation!")

            rc = self._docker_run(docker_args)
            if rc is None or rc != 0:
               print(
                  f"ERROR: {case_type} (T0={self.t0} "
                  f"exited with return code {rc}, re-try one more time ...",
                  flush=True,
               )
               #backup the failed run, this is the directory in the container
               src_dir = paths.container(f"{self.run_id}_failed")
               dst_dir = paths.container_run_dir
               rc_move = self._docker_move_dir( dst_dir, src_dir )
               if rc_move != 0:
                  print(
                     f"ERROR: {case_type} run 1 renaming {dst_dir} to {src_dir} "
                     f"exited with return code {rc_move}",
                     flush=True,
                  )
                  return rc_move
               checkpoint_dir = os.path.join(src_dir, "checkpoint" )
               if self._is_empty_or_missing( checkpoint_dir ):
                   restart_rc = self._docker_run(docker_args)
               else:
                   restart_rc = self._docker_restart( src_dir, dst_dir, checkpoint_dir )

               if restart_rc is None or restart_rc != 0:
                   self.task.iface.var_set(self.task.ecf_path, "PRE_WORKDIR", self.working_dir  )
               return restart_rc

            # Initial run succeeded.
            return rc

    def runRTE_restart(self, working_dir: str, pass_num: int) -> int:
        # NOTE: the caller (NWMRunner) must have already mounted working_dir at
        # /ngwpc/run_ngen_failed via _mount_failed_workdir (done once up front so
        # regions can restart in parallel without racing on run.sh).
        return self.forecast_restart()
