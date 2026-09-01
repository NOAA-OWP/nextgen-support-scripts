#!/usr/bin/env bash
set -euo pipefail

# set sudo users, dnf packages, and python packages
ADD_USERS=(
  "ngen-pw-user"
  "miguel.pena"
  "peter.a.kronenberg"
  "christopher.nealen"
  "khalid.ali"
  "bijan.zarean"
  "christina.osumi"
  "mohammed.karim"
  "yuqiong.liu"
  "kyle.larkin"
  "matthew.deshotel"
  "max.kipp"
  "ian.todd"
  "taher.chegini"
)
PY_PIP_PKGS="Flask gunicorn"

# set startup_cluster script paths
REPO_URL="https://raw.githubusercontent.com/NGWPC/nwm-automation-scripts/development/parallel_works_scripts"
STARTUP_SCRIPT="startup_cluster.sh"
STARTUP_SCRIPT_PATH="/tmp/${STARTUP_SCRIPT}"

# also fetch extract_ngen_cli script from the same directory
EXTRACT_SCRIPT="extract_ngen_cli.sh"
EXTRACT_SCRIPT_PATH="/tmp/${EXTRACT_SCRIPT}"

# set mount_s3_buckets script path
MOUNT_SCRIPT="mount_s3_buckets.sh"
MOUNT_SCRIPT_PATH="/tmp/${MOUNT_SCRIPT}"

# fetch startup_cluster script
curl -fsSL --retry 3 --retry-connrefused "${REPO_URL}/${STARTUP_SCRIPT}" -o "$STARTUP_SCRIPT_PATH"
chmod +x "$STARTUP_SCRIPT_PATH"

# fetch extract_ngen_cli script
curl -fsSL --retry 3 --retry-connrefused "${REPO_URL}/${EXTRACT_SCRIPT}" -o "$EXTRACT_SCRIPT_PATH"
chmod +x "$EXTRACT_SCRIPT_PATH"

# fetch mount_s3_buckets script
curl -fsSL --retry 3 --retry-connrefused "${REPO_URL}/${MOUNT_SCRIPT}" -o "$MOUNT_SCRIPT_PATH"
chmod +x "$MOUNT_SCRIPT_PATH"

# run script with environment variables
ADD_USERS="${ADD_USERS[*]}" \
PY_PIP_PKGS="$PY_PIP_PKGS" \
"$STARTUP_SCRIPT_PATH"
