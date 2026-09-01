"""Classes to manage arbitrary ecflow tasks and subtasks for needs of NWM operational forecasts.
Tasks are defined by the ecflow framework, but subtasks are not."""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime
from typing import Any, Callable

import ecflow

from ecf_task_mgr.constants import AoiType, ECFVariableSuffix, SubtaskType
from ecf_task_mgr.ecf_interface import EcflowInterface
from ecf_task_mgr.metadata import RunLogEntry, SubtaskInfoVarEntry, TaskPath
from ecf_task_mgr.utils import datetime_to_str_safe

logger = logging.getLogger("ecf_task_mgr.tasks")


class Task:
    """Represents ecFlow task.
    Contains reference to low-level client connection and high-level interface object.
    Contains Subtask factory.

    The dunders for str and repr are defined to return the task's full ecFlow path string,
    for convenience when passing instances of this class into client/interface methods."""

    def __init__(
        self,
        conn: Any,  # TODO add EcflowConnection type hint after resolving circular imports
        ecf_task_path: TaskPath,
        ecf_tryno: int,
        ecf_pass: str,
        ecf_rid: str,
    ) -> None:
        self._ecf_tryno = ecf_tryno
        self._ecf_pass = ecf_pass
        self._ecf_rid = ecf_rid
        self._subtasks: list[Subtask] = []

        self.ecf_path = ecf_task_path
        self.status: ecflow.State = ecflow.State.queued
        self.iface = EcflowInterface(conn)

    def __str__(self) -> str:
        return str(self.ecf_path)

    def __repr__(self) -> str:
        return self.__str__()

    def init_task(self) -> None:
        self.status = ecflow.State.active
        self.iface.update_task_status(self)

    def complete_task(self) -> None:
        self.status = ecflow.State.complete
        self.iface.update_task_status(self)

    def abort_task(self, reason: str = "") -> None:
        self.status = ecflow.State.aborted
        self.iface.update_task_status(self, reason)

    def create_subtask(
        self,
        subtask_type: SubtaskType,
        cycle_dt: datetime,
        aoi_type: AoiType,
        aoi_id: str,
        run_callback: Callable | None = None,
        run_callback_args: list | None = None,
        run_callback_kwargs: dict | None = None,
    ) -> Subtask:
        subtask = Subtask(
            task=self,
            subtask_type=subtask_type,
            cycle_dt=cycle_dt,
            aoi_type=aoi_type,
            aoi_id=aoi_id,
            run_callback=run_callback,
            run_callback_args=run_callback_args
            if run_callback_args is not None
            else [],
            run_callback_kwargs=run_callback_kwargs
            if run_callback_kwargs is not None
            else {},
        )
        self._subtasks.append(subtask)
        return subtask

    def run_subtask(self, subtask: Subtask, verbosity: int = 1) -> Any:
        """Execute a subtask's callback and return its result."""
        if subtask.run_callback is None:
            raise RuntimeError("subtask.run_callback is not set.")
        callable_name = getattr(
            subtask.run_callback, "__name__", repr(subtask.run_callback)
        )
        run_log_entry = RunLogEntry(
            subtask=subtask.full_identity_string,
            action="running",
            run_callback_name=callable_name,
            args=subtask.run_callback_args,
            kwargs=subtask.run_callback_kwargs,
        )
        if verbosity >= 1:
            logger.info(json.dumps(asdict(run_log_entry)))
        result = None
        exception = None
        try:
            result = subtask.run_callback(
                *subtask.run_callback_args,
                **subtask.run_callback_kwargs,
            )
        except Exception as exc:
            exception = exc
        done_log_entry = replace(
            run_log_entry,
            action="done running",
            result=repr(result),
            exception=str(exception) if exception else None,
        )
        if verbosity >= 1:
            logger.info(json.dumps(asdict(done_log_entry)))
        if exception is not None:
            raise exception
        return result


@dataclass
class SubtaskCallbackContext:
    """Minimal callback context to pass to callback functions so that they have
    the info they need to communicate with the ecFlow server about themselves."""

    task_path: str
    subtask_var_base: str
    var_info: str = field(init=False)
    var_status: str = field(init=False)

    def __post_init__(self) -> None:
        self.var_info = f"{self.subtask_var_base}{ECFVariableSuffix.INFO}"
        self.var_status = f"{self.subtask_var_base}{ECFVariableSuffix.STATUS}"

    @property
    def task(self) -> str:
        """Alias for ``subtask_var_info_append`` since it expects the provided object to have a ``task`` attribute."""
        return self.task_path


class Subtask:
    """Subtask with generic callable and reporting abilities. Not defined by ecflow framework itself.

    Contains:
        The instance of its parent Task.
        ID information.
        A generic callable (and associated args and kwargs for the callable) to be executed.

    Can make calls to the ecflow server via its parent Task's EcflowInterface attribute,
    for reporting status and appending other info to a ECF variable.
    """

    def __init__(
        self,
        task: Task,
        ### Attributes of the subtask used for identity and server variable management
        subtask_type: SubtaskType,  # Not built-in to ecflow; defined by this package.
        cycle_dt: datetime,  # Not built-in to ecflow; defined by NOAA NCO (see NCO prod_utils).
        aoi_type: AoiType,  # Not built-in to ecflow; defined by this package.
        aoi_id: str,  # Not built-in to ecflow; defined by this package.
        ### Execution
        run_callback: Callable | None = None,
        run_callback_args: list | None = None,
        run_callback_kwargs: dict | None = None,
    ) -> None:
        self.task = task
        self._subtask_type = subtask_type
        self._cycle_dt = cycle_dt
        self._aoi_type = aoi_type
        self._aoi_id = aoi_id

        self.status: ecflow.State = ecflow.State.queued
        self.run_callback = run_callback
        self.run_callback_args = run_callback_args if run_callback_args else []
        self.run_callback_kwargs = run_callback_kwargs if run_callback_kwargs else {}
        self.create_subtask_var_pair()

    def create_subtask_var_pair(self) -> None:
        """Create the info and status variables on the server for this subtask."""
        self.task.iface.subtask_var_pair_create(self)

    @property
    def subtask_var_base(self) -> str:
        """String that uniquely identifies this subtask instance, used for defining ecflow variable for storing status and other information about this subtask."""
        return f"{self._subtask_type}__{datetime_to_str_safe(self._cycle_dt)}__{self._aoi_type}__{self._aoi_id}"

    @property
    def full_identity_string(self) -> str:
        """String that uniquely identifies this subtask instance, used for defining ecflow variable for storing status and other information about this subtask."""
        return f"{self.task.ecf_path}__{self.subtask_var_base}"

    @property
    def _hashed_identity_string(self) -> str:
        digest = hashlib.md5(self.full_identity_string.encode()).hexdigest()[:12]
        return f"{digest}"

    @property
    def var_status(self) -> str:
        """Full name of this subtask's "status" variable."""
        return f"{self.subtask_var_base}{ECFVariableSuffix.STATUS}"

    @property
    def var_info(self) -> str:
        """Full name of this subtask's "info" variable."""
        return f"{self.subtask_var_base}{ECFVariableSuffix.INFO}"

    @property
    def callback_context(self) -> SubtaskCallbackContext:
        """Minimal callback context to pass to callback functions so that they have
        the info they need to communicate with the ecFlow server about themselves."""
        return SubtaskCallbackContext(
            task_path=str(self.task.ecf_path),
            subtask_var_base=self.subtask_var_base,
        )

    def server_set_status(
        self, status: ecflow.State, reason: str = "", metadata: dict | None = None
    ) -> None:
        """Update subtask status and append a status/info lifecycle entry on the ecflow server.
        ``reason`` is an ecflow convention intended to be used when a task is being aborted."""
        self.status = status
        iface = self.task.iface
        iface.subtask_var_status_set(self, status)
        entry = SubtaskInfoVarEntry(status=status, reason=reason, data=metadata)
        iface.subtask_var_info_append(self, entry)
