"""Utility helpers for datetime formatting used across ecf_task_mgr."""

from __future__ import annotations

from datetime import datetime, timezone


def datetime_to_str_nco(dt: datetime) -> str:
    """Convert a UTC datetime to NCO prod_utils string format '%Y-%m-%d %H:%M:%S'."""
    if dt.tzinfo is None or dt.tzinfo.utcoffset(dt) != timezone.utc.utcoffset(None):
        raise ValueError("dt must have UTC timezone")
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def datetime_to_str_safe(dt: datetime) -> str:
    """Convert a UTC datetime to a system-safe string of format 'YYYYMMDD_HHMMSS_ffffff'."""
    if dt.tzinfo is None or dt.tzinfo.utcoffset(dt) != timezone.utc.utcoffset(None):
        raise ValueError("dt must have UTC timezone")
    return dt.strftime("%Y%m%d_%H%M%S_%f")
