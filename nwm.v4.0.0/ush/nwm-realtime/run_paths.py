import os


class RunPaths:
    """Resolve host and container paths for a region's RTE run directory.

    Every RTE run works inside a directory laid out as

        <root>/regionalization/<formulation_dir>/<run_id>

    and that same directory is reachable under different roots depending on
    whether it is named on the host or inside the container:

      - host working_dir                 -> /ngwpc/run_ngen        (in container)
      - host previous failed working_dir -> /ngwpc/run_ngen_failed (in container)

    (comout / previous_day_comout are not mounted into the container, so they are
    out of scope for this helper.)

    An instance is bound to one ``(working_dir, formulation_dir, run_id)``. Its
    joiners are *relative to the formulation directory*, so callers name the
    run-id-level component explicitly to match how the RTE lays things out:

        p.container(run_id)                 .../<formulation_dir>/<run_id>
        p.container(f"{run_id}_state_save") .../<formulation_dir>/<run_id>_state_save
        p.container(run_id, "state_save")   .../<formulation_dir>/<run_id>/state_save
        p.container()                       .../<formulation_dir>

    with ``host`` / ``failed_container`` behaving the same way against their
    respective roots, and :meth:`to_container` mapping an arbitrary host path
    under working_dir to its /ngwpc/run_ngen equivalent.
    """

    #: Container mount points for the working directory and the previous failed
    #: working directory (see NWMForecast._mount_failed_workdir).
    RUN_NGEN = "/ngwpc/run_ngen"
    RUN_NGEN_FAILED = "/ngwpc/run_ngen_failed"

    #: Sub-directory, under each root, that holds the per-formulation run dirs.
    REGIONALIZATION = "regionalization"

    def __init__(self, working_dir: str, formulation_dir: str, run_id: str):
        self.working_dir = working_dir
        self.formulation_dir = formulation_dir
        self.run_id = run_id

    # ------------------------------------------------------------------ #
    # Formulation-dir-relative joiners
    # ------------------------------------------------------------------ #

    def _rel(self, *parts: str) -> str:
        """Path of *parts under regionalization/<formulation_dir>."""
        return os.path.join(self.REGIONALIZATION, self.formulation_dir, *parts)

    def host(self, *parts: str) -> str:
        """Host path under working_dir/regionalization/<formulation_dir>."""
        return os.path.join(self.working_dir, self._rel(*parts))

    def container(self, *parts: str) -> str:
        """Container path under /ngwpc/run_ngen/regionalization/<formulation_dir>."""
        return os.path.join(self.RUN_NGEN, self._rel(*parts))

    def failed_container(self, *parts: str) -> str:
        """Container path under
        /ngwpc/run_ngen_failed/regionalization/<formulation_dir> (the previous
        failed job's working directory)."""
        return os.path.join(self.RUN_NGEN_FAILED, self._rel(*parts))

    # ------------------------------------------------------------------ #
    # Run-directory conveniences
    # ------------------------------------------------------------------ #

    @property
    def host_run_dir(self) -> str:
        """working_dir/regionalization/<formulation_dir>/<run_id>."""
        return self.host(self.run_id)

    @property
    def container_run_dir(self) -> str:
        """/ngwpc/run_ngen/regionalization/<formulation_dir>/<run_id>."""
        return self.container(self.run_id)

    @property
    def failed_container_run_dir(self) -> str:
        """/ngwpc/run_ngen_failed/regionalization/<formulation_dir>/<run_id>."""
        return self.failed_container(self.run_id)

    # ------------------------------------------------------------------ #
    # Generic host -> container mapping
    # ------------------------------------------------------------------ #

    def to_container(self, host_path: str) -> str:
        """Map any host path under working_dir to its /ngwpc/run_ngen equivalent."""
        return os.path.join(self.RUN_NGEN, os.path.relpath(host_path, self.working_dir))
