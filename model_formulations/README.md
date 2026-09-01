
# Model Formulations

A model formulation is a combination of ngen-suported models that account for various hydrologic mechanics such as runoff, infiltration, snowmelt, evaporation, routing, and more.

## Setup

### For dev uploading:

Run these from the repo root.

```shell
aws s3 cp "model_formulations/formulations_orig.tsv" "s3://ngwpc-dev/msw/"
aws s3 cp "model_formulations/formulations_munged.tsv" "s3://ngwpc-dev/msw/"
aws s3 cp "model_formulations/formulations_munged_setup_results.tsv" "s3://ngwpc-dev/msw/"
```

### For user downloading:

```shell
aws s3 cp "s3://ngwpc-dev/msw/formulations_orig.tsv" "./model_formulations/"
aws s3 cp "s3://ngwpc-dev/msw/formulations_munged.tsv" "./model_formulations/"
aws s3 cp "s3://ngwpc-dev/msw/formulations_munged_setup_results.tsv" "./model_formulations/"
```

## Files

### formulations_orig.tsv

Prepared by hand. A pasting of a Confluence table listing the formulations. In the source table, color-coding is used to assign status to each cell. The color-coding is not applied to this copy.

### formulations_munged.tsv

Prepared by hand. Based on `formulations_orig.tsv`. Rearranged s.t. each row contains 1 formulation. Additional columns (some empty) added for coded MSWM equivalent (csv values that pass to `models=` param), status, root zone usage, etc.

### formulations_munged_setup.tsv

Created by script. Based on `formulations_munged.tsv`, but with the following columns populated: "formulation_mswm", "uses_root_zone".

## Running

```shell
# Set up the formulations list coded in MSWM `models=` csv format (writes new tsv file)
python -um model_formulations.formulations_setup
# Read the previous tsv file and run the formulations
See `nwm-rte` script `bin_mounted/parse_test_results.py` and its example call in ./run_tests.sh
```
