import os

from da_preprocessor import DAPreprocessor


class USACEPreprocessor(DAPreprocessor):
    """USACE (Army Corps of Engineers) timeslices.

    Turns the CWMS JSON files downloaded from the USACE data service into
    15-minute *.usaceTimeSlice.ncdf timeslices. Replaces the v3.0.6
    exnwm_ace_timeslices.sh together with ace_download/analysis/nwmcopy.sh.
    """

    @property
    def tool(self) -> str:
        return os.path.join(self.streamflow_dir, "ace_download", "analysis",
                            "make_time_slice_from_ace.py")

    @property
    def site_file(self) -> str:
        """CWMS site list mapping (office, gage) to a USACE gage index. This is
        the same file the download step feeds to CWMS_download_current.py -- the
        one in analysis/ carries different column names and is not usable here."""
        return os.path.join(self.streamflow_dir, "ace_download",
                            "stream_flow_download", "site-file.csv")

    def copy_raw_data(self) -> int:
        return self._copy_raw_files(self.dcom_dir(self.DCOM_SUBDIR_USACE), self.raw_dir)

    def copy_existing_files(self) -> int:
        return self._copy_existing_products(self.COM_SUBDIR_USACE, self.SUFFIX_USACE)

    def execute(self) -> int:
        return self._run_tool(
            self.tool,
            ["-i", self.raw_dir, "-o", self.output_dir, "-s", self.site_file],
        )

    def move_outputs_to_storage(self) -> int:
        return self._store_outputs(self.SUFFIX_USACE, self.COM_SUBDIR_USACE)
