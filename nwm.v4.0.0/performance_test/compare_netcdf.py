#!/usr/bin/env python3
"""Compare NetCDF files after aligning data by their identifier variable.

The ``catchments`` and ``feature_id`` identifier conventions are detected
automatically. Variables using the identifier dimension are reordered before
their values are compared.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

try:
    from netCDF4 import Dataset
except ImportError as error:  # pragma: no cover - depends on runtime setup
    raise SystemExit(
        "compare_netcdf.py requires the 'netCDF4' package. Install it with "
        "'python3 -m pip install netCDF4'."
    ) from error


DEFAULT_LEFT = Path("./Output/catchment_output.nc")
DEFAULT_RIGHT = Path(
    "/media/test/tmp/regionalization/default_short/03S/Output/catchment_output.nc"
)
SUPPORTED_KEYS = ("catchments", "feature_id")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", nargs="?", type=Path, default=DEFAULT_LEFT)
    parser.add_argument("right", nargs="?", type=Path, default=DEFAULT_RIGHT)
    parser.add_argument(
        "--key", choices=SUPPORTED_KEYS,
        help="identifier variable and dimension to use (auto-detected by default)",
    )
    parser.add_argument(
        "--rtol", type=float, default=1e-5,
        help="relative tolerance for floating point values (default: %(default)g)",
    )
    parser.add_argument(
        "--atol", type=float, default=1e-8,
        help="absolute tolerance for floating point values (default: %(default)g)",
    )
    return parser.parse_args()


def select_key(left_file: Dataset, right_file: Dataset, requested_key: str | None) -> str:
    if requested_key:
        keys = (requested_key,)
    else:
        keys = SUPPORTED_KEYS
    for key in keys:
        if all(key in dataset.variables and key in dataset.dimensions for dataset in (left_file, right_file)):
            return key
    expected = requested_key or " or ".join(repr(key) for key in SUPPORTED_KEYS)
    raise ValueError(f"both files must contain {expected} as a variable and dimension")


def identifiers(dataset: Dataset, path: Path, key: str) -> np.ndarray:
    ids = np.asarray(dataset.variables[key][:]).reshape(-1)
    if ids.size != len(dataset.dimensions[key]):
        raise ValueError(f"{path}: {key!r} variable does not match its dimension")
    if np.unique(ids).size != ids.size:
        raise ValueError(f"{path}: {key!r} contains duplicate identifiers")
    return ids


def describe_location(
    index: tuple[int, ...], dimensions: tuple[str, ...], ids: np.ndarray, key: str
) -> str:
    parts = []
    for dimension, position in zip(dimensions, index):
        if dimension == key:
            parts.append(f"{key}={ids[position]}")
        else:
            parts.append(f"{dimension}={position}")
    return ", ".join(parts)


def compare_values(
    name: str,
    left: np.ndarray,
    right: np.ndarray,
    dimensions: tuple[str, ...],
    ids: np.ndarray,
    key: str,
    rtol: float,
    atol: float,
) -> str | None:
    if left.dtype.kind in "fciu" and right.dtype.kind in "fciu":
        equal = np.isclose(left, right, rtol=rtol, atol=atol, equal_nan=True)
    else:
        equal = left == right
    if np.all(equal):
        return None

    index = tuple(np.argwhere(~equal)[0])
    location = describe_location(index, dimensions, ids, key)
    return (
        f"{name}: values differ at {location}: "
        f"{left[index]!r} != {right[index]!r}"
    )


def compare(
    left_path: Path, right_path: Path, rtol: float, atol: float, requested_key: str | None
) -> tuple[str, list[str]]:
    problems: list[str] = []
    with Dataset(left_path) as left_file, Dataset(right_path) as right_file:
        left_file.set_auto_mask(False)
        right_file.set_auto_mask(False)
        key = select_key(left_file, right_file, requested_key)

        if set(left_file.dimensions) != set(right_file.dimensions):
            problems.append("dimension names differ")
        for name in set(left_file.dimensions) & set(right_file.dimensions):
            if len(left_file.dimensions[name]) != len(right_file.dimensions[name]):
                problems.append(f"dimension {name!r} has different lengths")

        left_variables = set(left_file.variables)
        right_variables = set(right_file.variables)
        if left_variables != right_variables:
            missing_left = sorted(right_variables - left_variables)
            missing_right = sorted(left_variables - right_variables)
            if missing_left:
                problems.append(f"variables missing from left file: {', '.join(missing_left)}")
            if missing_right:
                problems.append(f"variables missing from right file: {', '.join(missing_right)}")
            return key, problems

        left_ids = identifiers(left_file, left_path, key)
        right_ids = identifiers(right_file, right_path, key)
        right_index = {identifier: index for index, identifier in enumerate(right_ids)}
        if set(left_ids) != set(right_ids):
            problems.append(f"the files contain different {key} identifier sets")
            return key, problems
        reorder = np.fromiter((right_index[identifier] for identifier in left_ids), dtype=int)

        for name in sorted(left_variables):
            left_var, right_var = left_file.variables[name], right_file.variables[name]
            dimensions = left_var.dimensions
            if dimensions != right_var.dimensions:
                problems.append(f"{name}: dimensions differ ({dimensions} != {right_var.dimensions})")
                continue
            left_values = np.asarray(left_var[:])
            right_values = np.asarray(right_var[:])
            if key in dimensions:
                axis = dimensions.index(key)
                right_values = np.take(right_values, reorder, axis=axis)
            if left_values.shape != right_values.shape:
                problems.append(f"{name}: shapes differ ({left_values.shape} != {right_values.shape})")
                continue
            difference = compare_values(
                name, left_values, right_values, dimensions, left_ids, key, rtol, atol
            )
            if difference:
                problems.append(difference)
    return key, problems


def main() -> int:
    args = parse_args()
    if args.rtol < 0 or args.atol < 0:
        raise SystemExit("--rtol and --atol must be non-negative")
    for path in (args.left, args.right):
        if not path.is_file():
            raise SystemExit(f"File not found: {path}")
    try:
        key, problems = compare(args.left, args.right, args.rtol, args.atol, args.key)
    except (OSError, ValueError) as error:
        raise SystemExit(f"Comparison failed: {error}") from error
    if problems:
        print("Files are not scientifically identical:")
        print("\n".join(f"- {problem}" for problem in problems))
        return 1
    print(
        f"Files are scientifically identical using {key!r} "
        f"(rtol={args.rtol:g}, atol={args.atol:g})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
