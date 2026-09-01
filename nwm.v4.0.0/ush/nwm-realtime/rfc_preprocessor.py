import os
from datetime import timedelta

from da_preprocessor import DAPreprocessor


class RFCPreprocessor(DAPreprocessor):
    """RFC reservoir forecast time series.

    Turns the PI XML forecasts pulled from the RFC FTP server into
    *.RFCTimeSeries.ncdf files. Replaces the v3.0.6 exnwm_rfc_timeseries.sh
    together with rfc_ingestion/nwmrfccopy.sh.

    RFC differs from the timeslice cases in two ways, both inherited from
    nwm_rfc_copy/nwm_rfc_postcopy: an RFC forecast covers days rather than hours,
    so the recycled products span whole days instead of the last four cycles, and
    the products are not filtered by the four-cycle window on the way out either.
    """

    # Days of previously created time series fed back to the tool, in addition to
    # the current day
    RECYCLE_DAYS = 3

    @property
    def tool(self) -> str:
        return os.path.join(self.da_engine_dir, "rfc_ingestion",
                            "make_time_series_from_pi_xml.py")

    @property
    def site_file(self) -> str:
        """RFC reservoir locations ingested into the NWM."""
        return os.path.join(
            self.da_engine_dir, "rfc_ingestion",
            "RFC_Reservoir_Locations_for_Forecast_Ingest_into_NWM_All_RFCs.csv",
        )

    def copy_raw_data(self) -> int:
        return self._copy_raw_files(self.dcom_dir(self.DCOM_SUBDIR_RFC), self.raw_dir)

    def copy_existing_files(self) -> int:
        """Recycle every time series of the current and previous RECYCLE_DAYS days
        -- unlike the timeslice cases, without a four-cycle cutoff."""
        rc = 0
        for days_back in range(self.RECYCLE_DAYS + 1):
            day = (self.t0 - timedelta(days=days_back)).strftime("%Y%m%d")
            com = self.com_for_day(day)
            if com is None:
                print(f"WARNING: No COM directory for {day}; "
                      "its time series are not recycled", flush=True)
                continue
            rc |= self._copy_products(
                os.path.join(com, self.COM_SUBDIR_RFC), self.SUFFIX_RFC,
                recent_only=False,
            )
        return rc

    def execute(self) -> int:
        return self._run_tool(
            self.tool,
            ["-i", self.raw_dir, "-o", self.output_dir, "-s", self.site_file],
        )

    def move_outputs_to_storage(self) -> int:
        return self._store_outputs(self.SUFFIX_RFC, self.COM_SUBDIR_RFC,
                                   recent_only=False)
