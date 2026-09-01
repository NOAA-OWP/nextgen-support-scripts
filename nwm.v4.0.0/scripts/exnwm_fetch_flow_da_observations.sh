#!/usr/bin/env bash 

#################################################################################
#  Program Name: nwm
#                                                                               #
#  Author(s)/Contact(s): RTX & OWP                                              #
#                                                                               #
#  This script will fetch observed streamflow and reservoir flow data           #
#  from USGS, Env. Canada, USACE and RFC servers.                               #
#                                                                               #
#  Input: data service from USGS, Env. Canada, USACE and RFC                    #
#                                                                               #
#  Output: $DCOM/usgs_streamflow_observations/                                  #
#          nwm.$cycle.analysis_assim.conus.tm00.conus.nc                        #
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

msg="Starting streamflow observation download at `date`"

mkdir -p $DCOMROOT/
mkdir -p $DBNROOT/log
mkdir -p $DBNROOT/tmp

if [[ ${CASETYPE} == "FETCH_USGS" ]]; then
  mkdir -p $DBNROOT/user/usgs_api
  source ${HOMEnwm}/.env && export USGS_API_KEY && \
  python3 ${USHnwm}/nwm-data-assimilation/data_assimilation_engine/Streamflow_Scripts/usgs_download/stream_flow_download/usgs_current.py

elif [[ ${CASETYPE} == "FETCH_ENVCA" ]]; then
  mkdir -p $DBNROOT/user/can_streamgauge
  cd $DBNROOT/user/can_streamgauge
  source ${USHnwm}/nwm-data-assimilation/data_assimilation_engine/Streamflow_Scripts/nco_canada/streamflow_download/get_station_list.sh
  export err=$?; err_chk
  source ${USHnwm}/nwm-data-assimilation/data_assimilation_engine/Streamflow_Scripts/nco_canada/streamflow_download/get_canadian_streamgauge.sh
elif [[ ${CASETYPE} == "FETCH_USACE" ]]; then
  OUTDIR=$DCOMROOT/${PDY}/usace_streamflow
  mkdir -p ${OUTDIR}
  SITE_FILE=${USHnwm}/nwm-data-assimilation/data_assimilation_engine/Streamflow_Scripts/ace_download/stream_flow_download/site-file.csv
  python3 ${USHnwm}/nwm-data-assimilation/data_assimilation_engine/Streamflow_Scripts/ace_download/stream_flow_download/CWMS_download_current.py \
     -f json ${SITE_FILE} ${OUTDIR}
elif [[ ${CASETYPE} == "FETCH_RFC" ]]; then
  OUTDIR=$DCOMROOT/${PDY}/rfc_reservoir
  source ${HOMEnwm}/.env && export FTP_URL FTP_DIR FTP_USER FTP_PASS && \
    ${USHnwm}/nwm-data-assimilation/data_assimilation_engine/utils/download_ftp.sh ${OUTDIR} '*.xml'
fi

export err=$?; err_chk

msg="Ending streamflow observation download `date`"

set $setoff

echo ' '
echo -e "\n=====> Ending $0 at : `date`\n"
echo '***********************************'
