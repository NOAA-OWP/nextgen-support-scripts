"""ecf_task_mgr — Python OOP iface for ecflow task/subtask management."""

from ecf_task_mgr.constants import (
    AoiType,
    Domain,
    ECFVariableSuffix,
    ForcingConfigName,
    SubtaskType,
)
from ecf_task_mgr.ecf_interface import EcflowConnection, EcflowInterface
from ecf_task_mgr.logging_setup import setup_logging
from ecf_task_mgr.metadata import SubtaskInfoVarEntry, TaskPath
from ecf_task_mgr.tasks import Subtask, SubtaskCallbackContext, Task

setup_logging()

__all__ = [
    "AoiType",
    "EcflowConnection",
    "EcflowInterface",
    "SubtaskCallbackContext",
    "SubtaskInfoVarEntry",
    "TaskPath",
    "Task",
    "Subtask",
    "SubtaskType",
    "ECFVariableSuffix",
    "ForcingConfigName",
    "Domain",
]
