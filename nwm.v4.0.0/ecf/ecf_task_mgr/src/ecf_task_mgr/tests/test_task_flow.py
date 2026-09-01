"""End-to-end flow: construct all public classes and run a subtask through Task.run_subtask."""

import json
import logging
import socket
import time
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

import ecflow
import pytest

from ecf_task_mgr.constants import AoiType, LogFileType, SavedStateType, SubtaskType
from ecf_task_mgr.ecf_interface import EcflowConnection, EcflowInterface
from ecf_task_mgr.metadata import (
    NgenResult,
    NgenSavedState,
    NWMLogFile,
    SubtaskInfoVarEntry,
    TaskPath,
)
from ecf_task_mgr.tasks import SubtaskCallbackContext, Task

TEST_TASK_PATH = TaskPath(
    suite="nwm",
    family_outer="hourly",
    family_inner="nwm_analysis_assim",
    task="jnwm_conus_analysis_assim",
)

NWM_DEF_PATH = Path(__file__).resolve().parent / "data" / "nwm.def"

_TEST_IFACE: EcflowInterface | None = None


def sample_run_callback(arg1: str, arg2: str, *, kwarg1: str, kwarg2: str) -> str:
    """A sample / mock callback for testing Subtask behavior."""
    logging.info("Inside subtask sample callback, starting...")
    time.sleep(0.2)
    logging.info("Inside subtask sample callback...")
    time.sleep(0.2)
    logging.info("Inside subtask sample callback, ending...")
    return "_".join([arg1, arg2, kwarg1, kwarg2])


def sample_run_callback_with_ngen_result(context: SubtaskCallbackContext) -> NgenResult:
    """Simulate a subtask that runs a NWM ngen realization including checkpointing and state saving.
    Send the ``NgenSavedState`` to the ecFlow server via the subtask info variable, and return that
    ``NgenSavedState`` instance to the caller so that the caller can verify that roundtripping the
    ``NgenSavedState`` through the server results in an equivalent object."""
    log_files = []
    for log_type in LogFileType:
        if log_type == LogFileType.NGEN_RANK:
            log_files.append(
                NWMLogFile(
                    log_type=log_type,
                    log_path="/foobar/logs/ngen_rank_0.log",
                    log_rank=0,
                )
            )
            log_files.append(
                NWMLogFile(
                    log_type=log_type,
                    log_path="/foobar/logs/ngen_rank_1.log",
                    log_rank=1,
                )
            )
        else:
            log_files.append(
                NWMLogFile(
                    log_type=log_type,
                    log_path=f"/foobar/logs/{log_type.value}.log",
                    log_rank=None,
                )
            )

    ngen_saved_states = [
        NgenSavedState(
            state_type=SavedStateType.CHECKPOINT, state_path="/foobar/checkpoint/3"
        ),
        NgenSavedState(
            state_type=SavedStateType.COMPLETED, state_path="/foobar/state_save"
        ),
    ]
    ngen_result = NgenResult(log_files=log_files, ngen_saved_states=ngen_saved_states)

    _TEST_IFACE.subtask_var_info_append(
        context,
        SubtaskInfoVarEntry(
            status=ecflow.State.complete,
            data={"ngen_result": asdict(ngen_result)},
        ),
    )
    return ngen_result


@pytest.fixture()
def stub_settings(tmp_path):
    """Write a minimal ecflow-settings.json into a temp directory."""
    settings = tmp_path / "ecflow-settings.json"
    settings.write_text('{"host": "localhost", "port": 3141}')
    return settings


@pytest.fixture()
def conn(stub_settings):
    connection = EcflowConnection(settings_path=stub_settings)
    yield connection


@pytest.fixture(autouse=True)
def load_nwm_suite(conn):
    conn.load_suite(NWM_DEF_PATH, force=True)


@pytest.fixture(autouse=True)
def shared_iface(conn):
    global _TEST_IFACE
    _TEST_IFACE = EcflowInterface(conn=conn)


@pytest.fixture()
def task(conn):
    return Task(
        conn=conn,
        ecf_task_path=TEST_TASK_PATH,
        ecf_tryno=1,
        ecf_pass="abc123",
        ecf_rid="12345",
    )


@pytest.fixture()
def subtask(task):
    return task.create_subtask(
        subtask_type=SubtaskType.NONE,
        cycle_dt=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
        aoi_type=AoiType.GAGE,
        aoi_id="01123000",
        run_callback=sample_run_callback,
        run_callback_args=["one", "two"],
        run_callback_kwargs={"kwarg1": "three", "kwarg2": "four"},
    )


class TestEcflowConnection:
    def test_connection(self):
        """Confirm a local ecflow server is reachable at localhost:3141."""
        logging.info("Testing raw socket connection to ecflow server")
        with socket.create_connection(("localhost", 3141), timeout=2):
            pass

    def test_connection_ecflow_client(self):
        """Confirm a local ecflow server responds to a Python ecflow client ping."""
        logging.info("Testing ecflow.Client connection and ping to ecflow server")
        client = ecflow.Client("localhost", 3141)
        client.ping()


class TestTaskFlow:
    def test_connection_constructed(self, conn):
        assert conn.host == "localhost"
        assert conn.port == 3141

    def test_task_constructed(self, task):
        assert (
            str(task.ecf_path)
            == "/nwm/hourly/nwm_analysis_assim/jnwm_conus_analysis_assim"
        )

    def test_subtask_constructed(self, subtask):
        assert subtask.subtask_var_base.endswith("__01123000")

    def test_subtask_run_noop(self, task, subtask):
        result = task.run_subtask(subtask, verbosity=1)
        assert result == "one_two_three_four"

    def test_subtask_run_noop_with_return_value(self, task):
        st = task.create_subtask(
            subtask_type=SubtaskType.NONE,
            cycle_dt=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
            aoi_type=AoiType.GAGE,
            aoi_id="01123000",
            run_callback=sample_run_callback,
            run_callback_args=["foo", "bar"],
            run_callback_kwargs={"kwarg1": "baz", "kwarg2": "qux"},
        )
        assert task.run_subtask(st, verbosity=1) == "foo_bar_baz_qux"

    def test_subtask_vars(self, subtask):
        """Verify that status and info variables were created automatically on subtask init."""
        task_path = str(subtask.task.ecf_path)

        subtask_status = _TEST_IFACE.var_fetch(task_path, subtask.var_status)
        subtask_info = _TEST_IFACE.var_fetch(task_path, subtask.var_info)
        logging.info(f"Subtask status: {repr(subtask_status)}")
        logging.info(f"Subtask info: {repr(subtask_info)}")

        logging.info("Setting new values for subtask vars...")
        _TEST_IFACE.subtask_var_status_set(subtask, ecflow.State.active)
        _TEST_IFACE.subtask_var_info_append(
            subtask,
            SubtaskInfoVarEntry(
                status=ecflow.State.active, data={"message": "First entry from pytest"}
            ),
        )
        _TEST_IFACE.subtask_var_info_append(
            subtask,
            SubtaskInfoVarEntry(
                status=ecflow.State.active, data={"message": "Second entry from pytest"}
            ),
        )
        subtask_status = _TEST_IFACE.var_fetch(task_path, subtask.var_status)
        subtask_info = _TEST_IFACE.var_fetch(task_path, subtask.var_info)
        logging.info(f"Subtask status: {repr(subtask_status)}")
        logging.info(f"Subtask info: {repr(subtask_info)}")

    def test_ngen_result(self, task):
        """Create a subtask that runs a callback that sends a NgenResult to the server (serialized to JSON),
        simulating a run that included checkpointing and state saving. The callback also returns the NgenResult
        instance. This test also then fetches the NgenResult (JSON string) from the ecFlow server and deserializes
        it back to a NgenResult instance, confirming that it matches the NgenResult that was submitted by the callback."""
        st = task.create_subtask(
            subtask_type=SubtaskType.NONE,
            cycle_dt=datetime(2026, 6, 15, 12, 0, 0, tzinfo=timezone.utc),
            aoi_type=AoiType.GAGE,
            aoi_id="01123000",
            run_callback=sample_run_callback_with_ngen_result,
        )
        st.run_callback_args = [st.callback_context]

        result = task.run_subtask(st, verbosity=0)

        info_raw = _TEST_IFACE.var_fetch(str(task.ecf_path), st.var_info)
        info_entries = json.loads(info_raw)
        final_entry = info_entries[-1]

        assert "data" in final_entry
        assert "ngen_result" in final_entry["data"]

        server_ngen_result_serialized = json.dumps(final_entry["data"]["ngen_result"])
        logging.info(
            f"Server-side NgenResult JSON, fetched from subtask info variable: {server_ngen_result_serialized}"
        )

        returned_ngen_result_serialized = json.dumps(asdict(result))
        assert server_ngen_result_serialized == returned_ngen_result_serialized

        assert len(result.ngen_saved_states) == 2
        assert {state.state_type for state in result.ngen_saved_states} == {
            SavedStateType.CHECKPOINT,
            SavedStateType.COMPLETED,
        }
