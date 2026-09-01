#!/usr/bin/env bash 

#################################################################################
#  Program Name: nwm
#                                                                               #
#  Author(s)/Contact(s): RTX & OWP                                              #
#                                                                               #
#  This script will preprocess observed streamflow and reservoir flow data      #
#  from USGS, Env. Canada, USACE and RFC servers.                               #
#                                                                               #
#  Input: Raw data file from USGS, Env. Canada, USACE and RFC                   #
#                                                                               #
#  Output: Timeslices for USGS, Env. Canda, USACE, and timeseries file          #
#          for RFC reservoirs                                                   #
#                                                                               #
#                                                                               #
# History:                                                                      #
#################################################################################
# ----------------------------------------------------------------------------- #
# Main script ----------------------------------------------

seton='-xa'
setoff='+xa'

set $setoff
echo ' '
echo '********************************************************'
echo '** National Water Model (NWM) Flow DA Download     **'
echo '********************************************************'
echo -e "\n=====> Starting $0 at : `date`\n"
set $seton

cd $DATA

msg="Starting streamflow observation preprocessing at `date`"

#
# Map the ecFlow CASETYPE onto the --case-type of the pre-processor. USGS and
# Env. Canada share one case: they are processed together so their timeslices
# can be merged in the same pass.
#
case ${CASETYPE} in
  PREPROCESS_USGS_N_ENVCA) case_type=USGS_N_ENVCA ;;
  PREPROCESS_USACE)        case_type=USACE ;;
  PREPROCESS_RFC)          case_type=RFC ;;
  *)
    echo "FATAL ERROR: unknown CASETYPE for DA pre-processing: ${CASETYPE}" >&2
    export err=1; err_chk
    exit 1
    ;;
esac

#
# nwm_da_preprocess.py stages the raw data and the previous cycles' products
# into $DATA, runs the nwm-data-assimilation make_*.py tools over them, and
# stores the results under ${COMOUT}/{usgs,canada,usace}_timeslices,
# ${COMOUT}/merged_usgs_and_ca_timeslices and ${COMOUT}/rfc_timeseries.
#
# The make_*.py tools need the data_assimilation_engine dependencies (netCDF4,
# numpy). Set DA_PYTHON to that interpreter if it is not the python3 running
# here; otherwise the tools are run with this same python3.
#
python3 ${USHnwm}/nwm-realtime/nwm_da_preprocess.py \
  --case-type ${case_type}                         \
  --pdy ${PDY}                                     \
  --cyc ${cyc}                                     \
  --package-dir ${HOMEnwm}                         \
  --working-dir ${DATA}                            \
  --comout ${COMOUT}                               \
  --precomout ${COMOUTm1}                          \
  --dcomroot ${DCOMROOT}

export err=$?; err_chk

msg="Ending streamflow observation preprocessing `date`"

set $setoff

echo ' '
echo -e "\n=====> Ending $0 at : `date`\n"
echo '***********************************'
