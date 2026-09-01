"""Script to build a set of machine-readable formulations (model groupings)
from a table of vernacular descriptions.

Usage:
    1. Run from repo root: python -um model_formulations.formulations_setup
"""

import itertools
import math
import os

import pandas as pd

from . import common as c


def get_models_list_from_formulation_description(
    formulation_descr_raw: str,
) -> list[str]:
    """Convert a formulation description into a models list"""
    parts = formulation_descr_raw.split("+")
    formulation_descr_cleaned_list = list(p.strip().lower() for p in parts)
    return formulation_descr_cleaned_list


def main():
    all_formulation_descr_lists = []

    df = pd.read_csv(c.INPUT_TSV_PATH, sep="\t")
    for i, row in df.iterrows():
        ### For parsing transposed table
        formulation_descr_raw = row["formulation_description"]
        formulation_descr_list = get_models_list_from_formulation_description(
            formulation_descr_raw
        )
        all_formulation_descr_lists.append(formulation_descr_list)

        formulation_mswm_codes_list = [
            c.MODEL_NAMES__TSV_VS_MSWM[m] for m in formulation_descr_list
        ]
        formulation_mswm_codes_csv = ",".join(formulation_mswm_codes_list)

        uses_root_zone = (
            "True"
            if any(type(m) is str and "rootzone" in m for m in formulation_descr_list)
            else "False"
        )

        df.at[i, "formulation_mswm"] = formulation_mswm_codes_csv
        df.at[i, "uses_root_zone"] = uses_root_zone

        print(f"uses_root_zone = {uses_root_zone}")
        print(f"formulation_mswm_codes_csv = {formulation_mswm_codes_csv}")

    models_unique = set(itertools.chain.from_iterable(all_formulation_descr_lists))
    print(f"Found {len(models_unique)} unique models: {models_unique}")

    ### NOTE ad-hoc code block for constructing keys of MODEL_NAMES__TSV_VS_MSWM dict
    # models_dict = {f: None for f in sorted(models_unique)}
    # print(models_dict)
    # return

    unexpected_models = models_unique - set(c.MODEL_NAMES__TSV_VS_MSWM)
    missing_models = set(c.MODEL_NAMES__TSV_VS_MSWM) - models_unique

    errors = []
    if unexpected_models:
        errors.append(f"Unexpected models: {unexpected_models}")
    if missing_models:
        errors.append(f"Missing models: {missing_models}")

    unsupported_formulations = []
    ###
    if unsupported_formulations:
        errors.append(
            ValueError(f"Unsupported formulations:{unsupported_formulations}")
        )

    if errors:
        raise ValueError(errors)

    print(f"Writing: {c.OUTPUT_TSV_PATH}")
    df.to_csv(c.OUTPUT_TSV_PATH, sep="\t", index=False)


if __name__ == "__main__":
    main()
