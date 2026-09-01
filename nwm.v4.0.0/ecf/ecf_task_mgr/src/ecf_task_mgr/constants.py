"""Module-level constants for the ecf_task_mgr package.
TODO remove Python 3.10 support and replace CustomStrEnum with built-in StrEnum."""

from enum import Enum


class CustomStrEnum(str, Enum):
    """Enum subclass that returns the value for str() and repr().

    This is a backport of the Python 3.11+ StrEnum type.
    """

    def __str__(self) -> str:
        return self.value

    def __repr__(self) -> str:
        return self.__str__()


class ECFVariableSuffix(CustomStrEnum):
    """Suffix appended to a subtask's base key to complete the full name of the 2 variables storing "status" and "info"."""

    INFO = "_info"
    STATUS = "_status"


class ForcingConfigName(CustomStrEnum):
    """NWM forecast configurations.

    Values taken from NWMRealtimeFcst in .../ush/nwm-realtime/nwm_realtime_fcst.py.
    """

    ANA = "AnA"
    SHORT_RANGE = "Short_Range"
    EXTENDED_ANA = "Extended_AnA"


class AoiType(CustomStrEnum):
    """Type of Area of Interest for a forecast (gage or VPU)"""

    GAGE = "gage"
    VPU = "vpu"


class SubtaskType(CustomStrEnum):
    """Allowed subtask types within an ecflow Task."""

    COLD_START = "cold_start"
    WARM_START = "warm_start"
    NONE = "no_subtask_type"


class Domain(CustomStrEnum):
    """Geographic domains supported by NWM.

    Values taken from NWMRealtimeFcst in .../ush/nwm-realtime/nwm_realtime_fcst.py.
    """

    CONUS = "CONUS"
    ALASKA = "Alaska"
    HAWAII = "Hawaii"
    PRVI = "PRVI"


class LogFileType(CustomStrEnum):
    """Types of log files supported by NWM / ngen.
    See nwm-rte ``ngen_logs.py`` and ``ngen_async.py``."""

    MSW_MGR = "msw"
    FCST_MGR = "fcst"
    CAL_MGR = "cal"
    NGEN_RANK = "ngen_rank"
    NGEN_STDOUT_STDERR = "ngen_stdout_stderr"


class SavedStateType(CustomStrEnum):
    """Types of saved states supported by NWM / ngen"""

    # Intended for restarts. Created at regular intervals throughout a forecast, e.g. when using nwm-rte CLI arg --checkpoint_interval.
    CHECKPOINT = "state_checkpoint"
    # Intended for Warmstarts informed by a completed Coldstart or AnA run. Created when using nwm-rte CLI arg --save_state.
    COMPLETED = "state_completed"
