import glob
import os
import re

from da_preprocessor import DAPreprocessor


class USGSandCAPreprocessor(DAPreprocessor):
    """USGS and Env. Canada timeslices, plus the merge of the two.

    Runs in one pass what v3.0.6 split across three jobs
    (exnwm_usgs_timeslices.sh, exnwm_canada_timeslices.sh and
    exnwm_merge_usgs_ca_timeslices.sh): USGS WaterML/CSV becomes
    *.usgsTimeSlice.ncdf, Env. Canada CSV becomes *.wscTimeSlice.ncdf, and every
    pair sharing a slice time is merged into *.causgsTimeSlice.ncdf. All three
    products are stored, each in its own COMOUT directory.

    The two sources keep separate raw-data directories under working_dir but share
    one output directory, which is what lets the merge step pair them up.
    """

    # Env. Canada names a timeslice YYYY-MM-DD_HH_MM_SS.<res>.wscTimeSlice.ncdf
    # where USGS uses YYYY-MM-DD_HH:MM:SS.<res>.usgsTimeSlice.ncdf, so pairing the
    # two means rewriting the time separators (the sed of the v3 merge script).
    _ENVCA_NAME_RE = re.compile(
        r"^(.*)_(\d{2})_(\d{2})_(\d{2})\.(\w+)\."
        + re.escape(DAPreprocessor.SUFFIX_ENVCA) + r"$"
    )

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Timeslice pairs that failed to merge. Kept so that a merge failure does
        # not cost us the USGS and Env. Canada products of this cycle: execute()
        # finishes and the products are stored, and move_outputs_to_storage()
        # reports the failure afterwards.
        self.merge_failures = 0

    # ------------------------------------------------------------------ #
    # Tools and per-source paths
    # ------------------------------------------------------------------ #

    @property
    def usgs_tool(self) -> str:
        return os.path.join(self.streamflow_dir, "usgs_download", "analysis",
                            "make_time_slice_from_usgs_waterml.py")

    @property
    def envca_tool(self) -> str:
        return os.path.join(self.streamflow_dir, "nco_canada", "timeslices_scripts",
                            "make_time_slice_from_canada.py")

    @property
    def merge_tool(self) -> str:
        return os.path.join(self.streamflow_dir, "merge_timeslices",
                            "merge_timeslices.py")

    @property
    def usgs_raw_dir(self) -> str:
        return os.path.join(self.raw_dir, "usgs")

    @property
    def envca_raw_dir(self) -> str:
        return os.path.join(self.raw_dir, "canada")

    # ------------------------------------------------------------------ #
    # Steps
    # ------------------------------------------------------------------ #

    def copy_raw_data(self) -> int:
        rc = self._copy_raw_files(self.dcom_dir(self.DCOM_SUBDIR_USGS), self.usgs_raw_dir)
        rc |= self._copy_raw_files(self.dcom_dir(self.DCOM_SUBDIR_ENVCA), self.envca_raw_dir)
        return rc

    def copy_existing_files(self) -> int:
        rc = self._copy_existing_products(self.COM_SUBDIR_USGS, self.SUFFIX_USGS)
        rc |= self._copy_existing_products(self.COM_SUBDIR_ENVCA, self.SUFFIX_ENVCA)
        return rc

    def execute(self) -> int:
        rc = self._run_tool(self.usgs_tool, ["-i", self.usgs_raw_dir, "-o", self.output_dir])
        if rc != 0:
            return rc

        rc = self._run_tool(self.envca_tool, ["-i", self.envca_raw_dir, "-o", self.output_dir])
        if rc != 0:
            return rc

        self._merge_timeslices()
        return 0

    def move_outputs_to_storage(self) -> int:
        rc = self._store_outputs(self.SUFFIX_USGS, self.COM_SUBDIR_USGS)
        rc |= self._store_outputs(self.SUFFIX_ENVCA, self.COM_SUBDIR_ENVCA)
        rc |= self._store_outputs(self.SUFFIX_MERGED, self.COM_SUBDIR_MERGED)
        if self.merge_failures:
            print(f"ERROR: {self.merge_failures} timeslice pair(s) failed to merge",
                  flush=True)
            rc |= 1
        return rc

    # ------------------------------------------------------------------ #
    # Merge
    # ------------------------------------------------------------------ #

    def _usgs_and_merged_names(self, envca_name: str) -> tuple | None:
        """The USGS and merged filenames matching an Env. Canada timeslice, or
        None when the name does not follow the Env. Canada convention."""
        m = self._ENVCA_NAME_RE.match(envca_name)
        if m is None:
            return None
        date, hour, minute, second, resolution = m.groups()
        stem = f"{date}_{hour}:{minute}:{second}.{resolution}"
        return f"{stem}.{self.SUFFIX_USGS}", f"{stem}.{self.SUFFIX_MERGED}"

    def _merge_timeslices(self) -> None:
        """Append each Env. Canada timeslice to the USGS timeslice of the same
        slice time, writing a third *.causgsTimeSlice.ncdf file.

        v3.0.6 overwrote the USGS file with the merged one so that nwm_postcopy
        had a *usgsTimeSlice.ncdf to ship into merged_usgs_and_ca_timeslices; here
        the merged file is stored under its own name and the USGS timeslices are
        left holding USGS observations only.

        Failures are counted rather than raised so that one bad pair does not cost
        us the rest of the cycle's products; move_outputs_to_storage() fails the
        task once everything has been stored.
        """
        merged = 0
        for envca_path in sorted(glob.glob(
                os.path.join(self.output_dir, f"*.{self.SUFFIX_ENVCA}"))):
            names = self._usgs_and_merged_names(os.path.basename(envca_path))
            if names is None:
                print(f"WARNING: Unrecognized Env. Canada filename, not merged: "
                      f"{envca_path}", flush=True)
                continue

            usgs_path = os.path.join(self.output_dir, names[0])
            out_path = os.path.join(self.output_dir, names[1])
            if not os.path.isfile(usgs_path):
                # No USGS timeslice at this slice time; nothing to merge into.
                continue

            # merge_timeslices.py refuses to write over an existing out_file, so
            # clear a merge left behind by an earlier attempt in this working dir.
            if os.path.exists(out_path):
                os.remove(out_path)

            rc = self._run_tool(self.merge_tool, [
                "--in_file_new", envca_path,
                "--in_file_copy_addto", usgs_path,
                "--out_file", out_path,
            ])
            if rc != 0:
                print(f"ERROR: Could not merge {envca_path} into {usgs_path}", flush=True)
                self.merge_failures += 1
                continue
            merged += 1

        print(f"INFO: Merged {merged} USGS/Env. Canada timeslice pair(s)", flush=True)
