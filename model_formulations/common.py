"""Code common to various scripts in model_formulations"""

import os

THIS_SCRIPT_PARENT_DIR = os.path.dirname(os.path.abspath(__file__))

### Inputs
# INPUT_TSV_BASENAME = "formulations_orig.tsv"
INPUT_TSV_BASENAME = "formulations_munged.tsv"
"""From Confluence table of formulations"""
INPUT_TSV_PATH = os.path.join(THIS_SCRIPT_PARENT_DIR, INPUT_TSV_BASENAME)

### Outputs
OUTPUT_TSV_SETUP_BASENAME = "formulations_munged_setup.tsv"
OUTPUT_TSV_PATH = os.path.join(THIS_SCRIPT_PARENT_DIR, OUTPUT_TSV_SETUP_BASENAME)

FORMULATION_GROUPS = [
    "Machine Learning",
    "Hydrology",
    "Snow Hydrology",
    "Snow Glacier Hydrology",
]
"""Used when reading the raw Confluence table"""


MODEL_NAMES__TSV_VS_MSWM = {
    # TODO no sloth?
    # TODO no t-route?
    "casam": "lasam",
    "cfe-s": "cfe-s",
    "cfe-s_rootzone": "cfe-s",
    "cfe-x": "cfe-x",
    "cfe-x_rootzone": "cfe-x",
    "lstm": "lstm",
    "noah-om": "noah-owp-modular",
    "pet": "pet",
    "sac-sma": "sac-sma",
    "snow17": "snow-17",
    "soil freeze thaw": "sft",
    "soil moisture profiles": "smp",
    "topmodel": "topmodel",
    "topoflow": "topoflow-glacier",
    "ueb": "ueb",
}
"""Dict entries are {name from tsv: name coded for mswm}. Coded name taken from column 2 of mswm settings.py."""
