#!/usr/bin/env bash 

#################################################################################
#  Program Name: nwm
#                                                                               #
#  Author(s)/Contact(s): RTX & OWP                                             #
#                                                                               #
#  This script will execute the analysis assim using RTE.                      #
#  The CONUS short range will regrid the RAP, HRRR, STAGE IV and MRMS data.    #
#                                                                               #
#  Input: compath.py -o {rap,hrrr,mrms}/v#.#/                                   #
#                                                                               #
#  Output: $COMOUT/analysis_assim/                                             #
#          nwm.$cycle.analysis_assim.conus.tm00.conus.nc                       #
#                                                                               #
# For non-fatal errors output is witten to $DATA                                #
# History:                                                                      #
#################################################################################
# ----------------------------------------------------------------------------- #
# Main script ----------------------------------------------

seton='-xa'
setoff='+xa'

set $setoff
echo ' '
echo '********************************************************'
echo '** National Water Model (NWM) ANALYSIS ASSIM FORCING  **'
echo '********************************************************'
echo -e "\n=====> Starting $0 at : `date`\n"
set $seton

cd $DATA

msg="Starting $USHnwm/rte-nwm at `date`"

# Scan RTE log files in ${DATA}/logs/rte/ for warnings and errors.
# Prints all WARNING/ERROR/FATAL/CRITICAL/SEVERE lines and calls err_chk
# if any error-level lines are found, or if the log dir/files are missing.
check_rte_logs() {
    set $setoff
    local log_dir="${DATA}/logs/rte"

    if [[ ! -d "${log_dir}" ]]; then
        echo "ERROR: RTE log directory not found: ${log_dir}" >&2
        return 1
    fi

    local log_file
    log_file=$(ls -t "${log_dir}"/rte_*.log 2>/dev/null | head -1)
    if [[ -z "${log_file}" ]]; then
        echo "ERROR: No RTE log files found in ${log_dir}" >&2
        return 1
    fi
    echo "RTE log scan: scanning ${log_file}"

    local error_count=0 warning_count=0 info_count=0
    local file_warnings file_errors n

    n=$(grep -cE '^\S+[[:space:]]+RTE[[:space:]]+INFO[[:space:]]' \
        "${log_file}" 2>/dev/null) || true
    info_count=${n:-0}

    file_warnings=$(grep -E '^\S+[[:space:]]+RTE[[:space:]]+WARNING[[:space:]]' \
                    "${log_file}" 2>/dev/null) || true
    if [[ -n "${file_warnings}" ]]; then
        echo "${file_warnings}"
        n=$(grep -cE '^\S+[[:space:]]+RTE[[:space:]]+WARNING[[:space:]]' \
            "${log_file}" 2>/dev/null) || true
        warning_count=${n:-0}
    fi

    file_errors=$(grep -E '^\S+[[:space:]]+RTE[[:space:]]+(ERROR|FATAL|CRITICAL|SEVERE)[[:space:]]' \
                  "${log_file}" 2>/dev/null) || true
    if [[ -n "${file_errors}" ]]; then
        echo "${file_errors}"
        n=$(grep -cE '^\S+[[:space:]]+RTE[[:space:]]+(ERROR|FATAL|CRITICAL|SEVERE)[[:space:]]' \
            "${log_file}" 2>/dev/null) || true
        error_count=${n:-0}
    fi

    echo "RTE log scan: ${info_count} INFO message(s) found in ${log_dir}."
    if [[ ${warning_count} -gt 0 ]]; then
        echo "RTE log scan: ${warning_count} WARNING(s) found in ${log_dir}."
    fi
    if [[ ${error_count} -gt 0 ]]; then
        echo "RTE log scan: ${error_count} ERROR/FATAL/CRITICAL/SEVERE line(s) found in ${log_dir}." >&2
        return 1
    fi
    set $seton
}

#build the docker images for RTE
#start docker daemon
#sudo systemctl start docker
#
#cd ${USHnwm}/nwm-rte
#./ngen_rte_build.sh
#cd -

set +e   # Disable exit-on-error

# All regions (VPUs and/or basins) to run in this job are listed in the region
# file; each entry carries its own hydrofabric/formulation/catchment paths, so a
# single invocation runs every region.
REGION_FILE=${USHnwm}/nwm-realtime/region.json
echo "Using region file: ${REGION_FILE}"

# configure and run RTE (every region in REGION_FILE runs in one invocation)
if [[ ${CASETYPE} == "CONUS_ANALYSIS_ASSIM" ]]; then
  python3  ${USHnwm}/nwm-realtime/nwm_realtime_fcst.py    \
    --config-name "AnA"                                  \
    --domain "CONUS"                                     \
    --t0 "${PDY:0:4}-${PDY:4:2}-${PDY:6:2} ${cyc}:00:00" \
    --package-dir ${HOMEnwm}                             \
    --working-dir ${DATA}                                \
    --comout ${COMOUT}                                   \
    --previous-day-comout ${COMOUTm1}                    \
    --region-file "${REGION_FILE}"
elif [[ ${CASETYPE} == "CONUS_SHORT_RANGE" ]]; then
  python3  ${USHnwm}/nwm-realtime/nwm_realtime_fcst.py    \
    --config-name "Short_Range"                          \
    --domain "CONUS"                                     \
    --t0 "${PDY:0:4}-${PDY:4:2}-${PDY:6:2} ${cyc}:00:00" \
    --package-dir ${HOMEnwm}                             \
    --working-dir ${DATA}                                \
    --comout ${COMOUT}                                   \
    --previous-day-comout ${COMOUTm1}                    \
    --region-file "${REGION_FILE}"
elif [[ ${CASETYPE} == "CONUS_EXT_ANALYSIS_ASSIM" ]]; then
  export cyc=16
  python3  ${USHnwm}/nwm-realtime/nwm_realtime_fcst.py    \
    --config-name "Extended_AnA"                         \
    --domain "CONUS"                                     \
    --t0 "${PDY:0:4}-${PDY:4:2}-${PDY:6:2} ${cyc}:00:00" \
    --package-dir ${HOMEnwm}                             \
    --working-dir ${DATA}                                \
    --comout ${COMOUT}                                   \
    --previous-day-comout ${COMOUTm1}                    \
    --region-file "${REGION_FILE}"
fi

run_rc=$?
check_rte_logs
export err=$?; err_chk
if [ "$err" -ne 0 ]; then
  exit 1
fi

if [ "$run_rc" -ne 0 ]; then
  err_exit
  exit 1
fi

set -e   # stop on errors 

# Per-region output staging to COMOUT (products, logs, and warm states under
# ${COMOUT}/${cyc}/${CASETYPE}/<run_id>/) is done inside nwm_realtime_fcst.py by
# NWMForecast.move_outputs_to_storage. NWMRunner records per-region outcome in
# ${DATA}/job_status.json and sets the PRE_WORKDIR ecFlow variable (NONE on full
# success, else ${DATA}) used to detect and drive restart runs. Nothing here.

msg="Ending $USHnwm/rte-nwm at `date`"

set $setoff
echo ' '
echo -e "\n=====> Ending $0 at : `date`\n"
echo '***********************************'
