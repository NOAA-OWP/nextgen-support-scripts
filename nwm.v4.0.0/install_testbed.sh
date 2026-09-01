#!/usr/bin/env bash

set -xa
set -euo pipefail

# Default values
RTE_BRANCH="development-pw"
export ECF_PORT=3141

while getopts "p:b:" opt; do
case $opt in
p) export ECF_PORT=$OPTARG; echo "Use port $OPTARG";;
b) RTE_BRANCH=$OPTARG; echo "Use RTE branch: $OPTARG";;
\?) # Invalid option
   echo "Usage: $0 [-p <port>] [-b <RTE branch name>]"
   exit 1
   ;;
esac
done

export PACKAGEROOT="${PWD%/*}"
export NWM_PACKAGE_DIR="$(pwd)"
export OPSROOT="${OPSROOT:-/lfs/h1/ops/prod}"
export DATAROOT="${DATAROOT:-${HOME}/test/tmp}"
export ECF_OUT="${DATAROOT}"
export COMROOT="${COMROOT:-${OPSROOT}/com}"
export DBNROOT="${DBNROOT:-${OPSROOT}/dbn}"
export DCOMROOT="${DCOMROOT:-${OPSROOT}/dcom}"

echo "PACKAGEROOT=${PACKAGEROOT}"
echo "NWM_PACKAGE_DIR=${NWM_PACKAGE_DIR}"
echo "DATAROOT=${DATAROOT}"
echo "OPSROOT=${OPSROOT}"
echo "ECF_OUT=${ECF_OUT}"


function run_ecf_task() {
  local task_path="$1"
  echo "Triggering ${task_path} ..."
  docker exec ecflow-server bash -c "ecflow_client --run=${task_path}"
  while docker exec ecflow-server bash -c "ecflow_client --get_state=${task_path}" | grep -q "state:submitted\|state:active"; do
    sleep 5
    echo "  ... ${task_path} is running ..."
  done
  echo "${task_path} final state: $(docker exec ecflow-server bash -c "ecflow_client --get_state=${task_path}" | grep -o 'state:[^ ]*')"
}


PDY=$(date +"%Y%m%d")

sed -i -e "s|^\(\s\+\)edit ECF_HOME \".\+\"|\1edit ECF_HOME \"${NWM_PACKAGE_DIR}/ecf\"|" ecf/nwm.def
sed -i -e "s|^\(\s\+\)edit ECF_INCLUDE \".\+\"|\1edit ECF_INCLUDE \"${NWM_PACKAGE_DIR}/ecf\"|" ecf/nwm.def
sed -i -e "s|^\(\s\+\)+edit ECF_OUT \".\+\"|\1edit ECF_OUT \"${ECF_OUT}\"|" ecf/nwm.def

sed -i -e "s|^export DATAROOT=.*|export DATAROOT=${DATAROOT}|" ecf/model_envir.h
sed -i -e "s|^export OPSROOT=.*|export OPSROOT=${OPSROOT}|" ecf/model_envir.h
sed -i -e "s|^export COMROOT=.*|export COMROOT=${OPSROOT}/com|" ecf/model_envir.h
sed -i -e "s|^export DCOMROOT=.*|export DCOMROOT=${DCOMROOT}|" ecf/model_envir.h
sed -i -e "s|^export DBNROOT=.*|export DBNROOT=${DBNROOT}|" ecf/model_envir.h
sed -i -e "s|^export OPSCOMROOT=.*|export OPSCOMROOT=${OPSROOT}/com|" ecf/model_envir.h
sed -i -e "s|^export PACKAGEROOT=.*|export PACKAGEROOT=${PACKAGEROOT}|" ecf/model_envir.h

if [ ! -d "${NWM_PACKAGE_DIR}/ush/nwm-rte" ]; then
  echo "Installing RTE ..."
  cd "${NWM_PACKAGE_DIR}/ush"
  # TODO update this line to clone either the default branch or the development branch
  git clone -b ${RTE_BRANCH} https://github.com/NGWPC/nwm-rte.git
  cd ./nwm-rte/
  ./setup_clone_repos.sh https
  ./ngen_rte_build.sh
  cd "${NWM_PACKAGE_DIR}"
else
  echo "RTE already installed, skipping."
fi


sudo mkdir -p "${ECF_OUT}"
sudo mkdir -p "${ECF_OUT}/nwm/test"
sudo mkdir -p "${ECF_OUT}/nwm/hourly/nwm_analysis_assim"
sudo mkdir -p "${ECF_OUT}/nwm/hourly/nwm_short_range"
sudo mkdir -p "${ECF_OUT}/nwm/daily/nwm_extended_analysis_assim"
sudo mkdir -p "${ECF_OUT}/nwm/da_preprocessing/preprocess"
sudo mkdir -p "${ECF_OUT}/nwm/da_preprocessing/fetch_raw_data"
sudo mkdir -p "${ECF_OUT}/nwm/cleanup"

echo "Starting ecflow-server container ..."
cd "${NWM_PACKAGE_DIR}/ecflow-server"
sudo \
COMROOT="${COMROOT}"           \
DBNROOT="${DBNROOT}"           \
DCOMROOT="${DCOMROOT}"        \
NWM_PACKAGE_DIR="${NWM_PACKAGE_DIR}"          \
DATAROOT="${DATAROOT}"        \
ECF_PORT="${ECF_PORT}"        \
./ecflow-server-start.sh

echo "Loading NWM suite into server ..."
sudo docker exec ecflow-server bash -c "
  cd ${NWM_PACKAGE_DIR}/ecf && \
  ecflow_client --delete force yes /nwm 2>/dev/null || true && \
  ecflow_client --load=nwm.def && \
  ecflow_client --begin=nwm && \
  ecflow_client --restart && \
  ecflow_client --stats
"

echo "NWM v4.0.0 is installed (Docker approach). Running tests..."

#run_ecf_task /nwm/test/test_ngen_rte_noop
#run_ecf_task /nwm/test/test_ngen_rte_pytest
