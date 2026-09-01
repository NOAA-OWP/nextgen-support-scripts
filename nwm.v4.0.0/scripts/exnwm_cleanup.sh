#!/usr/bin/env bash

#################################################################################
#  Program Name: nwm cleanup                                                    #
#                                                                               #
#  Author(s)/Contact(s): RTX & OWP                                              #
#                                                                               #
#  Daily housekeeping. Removes aged run/observation data so the filesystem      #
#  does not fill up:                                                            #
#    - dated run directories  ${COMROOT}/nwm/*/nwm.YYYYMMDD                      #
#    - dated raw obs. dirs     ${DCOMROOT}/YYYYMMDD                              #
#    - dated dbn log files     ${DBNROOT}/log/*                                  #
#  older than CLEANUP_RETENTION_DAYS (default 3).                               #
#                                                                               #
#  Only date-named entries are ever considered, so structural parents such as   #
#  ${COMROOT}/nwm and ${COMROOT}/nwm/v4.0 are never at risk. Set                 #
#  CLEANUP_DRYRUN=YES to log what would be removed without deleting anything.    #
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
echo '** National Water Model (NWM) Daily Cleanup          **'
echo '********************************************************'
echo -e "\n=====> Starting $0 at : `date`\n"
set $seton

# Days of data to keep. "-mtime +N" matches entries whose last-modified age is
# more than N days, so this keeps roughly the last N days and errs on the side
# of keeping one extra day rather than deleting too much.
export CLEANUP_RETENTION_DAYS=${CLEANUP_RETENTION_DAYS:-3}
export CLEANUP_DRYRUN=${CLEANUP_DRYRUN:-NO}

#
# purge_matches ROOT DESC FINDARGS...
#
# Deletes every entry under ROOT matched by the given find arguments. ROOT must
# be a non-empty, existing directory (guards against an unset variable expanding
# to a bare "/find ..."). Missing roots are a warning, not an error: a testbed
# may not have populated all of them yet.
#
purge_matches () {
  local root="$1"; local desc="$2"; shift 2

  if [ -z "${root}" ]; then
    echo "ERROR: empty root path for ${desc}; skipping" >&2
    return 1
  fi
  if [ ! -d "${root}" ]; then
    echo "WARNING: ${desc} root does not exist: ${root}; skipping"
    return 0
  fi

  local count=0
  local target
  # -print0/read -d handles any path; find never descends into a matched dir
  # because we -prune it, so an aged directory is removed as a whole.
  while IFS= read -r -d '' target; do
    if [ "${CLEANUP_DRYRUN}" = "YES" ]; then
      echo "DRYRUN: would remove ${desc}: ${target}"
    else
      echo "INFO: removing ${desc}: ${target}"
      rm -rf "${target}"
    fi
    count=$((count + 1))
  done < <(find "$@" -print0)

  echo "INFO: ${desc}: ${count} aged ent(y/ies) $([ "${CLEANUP_DRYRUN}" = YES ] && echo 'matched' || echo 'removed') under ${root}"
  return 0
}

cd $DATA

msg="Starting daily cleanup at `date` (retention=${CLEANUP_RETENTION_DAYS} day(s), dryrun=${CLEANUP_DRYRUN})"
echo "${msg}"

rc=0

#
# COMROOT: dated run directories nested under ${COMROOT}/nwm/<ver>/nwm.YYYYMMDD.
# Restricted to the nwm.<8 digits> naming so ${COMROOT}/nwm and the version dir
# are never matched.
#
purge_matches "${COMROOT}" "COMROOT run dir" \
  "${COMROOT}" -type d \
  -name 'nwm.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' \
  -mtime +${CLEANUP_RETENTION_DAYS} -prune || rc=1

#
# DCOMROOT: dated raw-observation directories directly under the root
# (${DCOMROOT}/YYYYMMDD).
#
purge_matches "${DCOMROOT}" "DCOMROOT raw dir" \
  "${DCOMROOT}" -mindepth 1 -maxdepth 1 -type d \
  -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' \
  -mtime +${CLEANUP_RETENTION_DAYS} || rc=1

#
# DBNROOT/log: dated log files.
#
purge_matches "${DBNROOT}/log" "DBN log file" \
  "${DBNROOT}/log" -mindepth 1 -maxdepth 1 -type f \
  -mtime +${CLEANUP_RETENTION_DAYS} || rc=1

export err=${rc}; err_chk

msg="Ending daily cleanup at `date`"
echo "${msg}"

set $setoff
echo ' '
echo -e "\n=====> Ending $0 at : `date`\n"
echo '***********************************'
