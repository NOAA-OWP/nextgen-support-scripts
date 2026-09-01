######################################
# This file is used by RTX/OWP developers
# 
#######################################

export envir="test"
export model="nwm"
export nwm_ver=v4.0.0
#export maillist1="Zhengtao.Cui@rtx.com"
#export maillist2=$maillist1

export SITE=PWCLUSTER

export OPSROOT=/lfs/h1/ops/prod
export COMROOT=/lfs/h1/ops/prod/com
export DBNROOT=/lfs/h1/ops/prod/dbn
export DATAROOT=/home/Zhengtao.Cui/test/tmp
export OPSCOMROOT=/lfs/h1/ops/prod/com
export DCOMROOT=/lfs/h1/ops/prod/dcom
export PACKAGEROOT=/contrib/lfs/h1/owp/nwm/noscrub/SOMEBODY/test/packages/nwm-automation-scripts
 
export PACKAGEHOME=${PACKAGEHOME:-$PACKAGEROOT}/$model.${nwm_ver}
modelhome=$PACKAGEHOME
export HOME${model}=$modelhome
export KEEPDATA=NO

modelhome=$PACKAGEHOME
export HOME${model}=$modelhome
versionfile=$PACKAGEHOME/versions/run.ver
if [ -f "$versionfile" ]; then . $versionfile ; fi

#Define upstream data compath
export COMPATH=$OPSCOMROOT/nam:$OPSCOMROOT/hiresw:$OPSCOMROOT/gfs:$OPSCOMROOT/cfs:$OPSCOMROOT/rap:$OPSCOMROOT/hrrr:$OPSCOMROOT/blend:$OPSCOMROOT/pcpanl:$OPSCOMROOT/psurge:$OPSCOMROOT/stofs

#Define nwm data compath
export COMPATH=$COMPATH:$COMROOT/nwm

export DBNETROOT=/lfs/h1/ops/prod/dbnet
export PCOMROOT=${PCOMROOT:-/pcom/${envir}}
export SENDDBN=${SENDDBN:-NO}
export SENDDBN_NTC=${SENDDBN_NTC:-NO}
export SENDWEB=${SENDWEB:-NO}
export SENDECF=${SENDECF:-NO}
export SENDCOM=${SENDCOM:-YES}
export KEEPDATA=${KEEPDATA:-NO}

export PATH=${PACKAGEHOME}/prod_util.v2.0.14/ush:${PACKAGEHOME}/prod_util.v2.0.14/exec:$PATH
export NDATE=${PACKAGEHOME}/prod_util.v2.0.14/exec/ndate

#source /contrib/software/py_venv/testbed/bin/activate
