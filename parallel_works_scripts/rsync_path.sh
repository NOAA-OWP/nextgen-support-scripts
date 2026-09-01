#!/usr/bin/env bash
set -euo pipefail

# Script to rsync a path from a source host to multiple destination hosts.
# Use this to copy files from one Parallel Works cluster to multiple others.
# Requires passwordless SSH access to source and destination hosts.

# defaults (can be overridden by flags/env)
SOURCE="${SOURCE:-}"
SRC_PATH="${SRC_PATH:-}"
DESTS="${DESTS:-}"            # comma- or space-separated list: "user@ip1,user@ip2" or "user@ip1 user@ip2"
DST_PATH="${DST_PATH:-}"
SELINUX_RELABEL="${SELINUX_RELABEL:-1}"  # 1 = run restorecon on dests, 0 = skip

usage() {
    cat <<'USAGE'
usage:
  rsync_path.sh --source USER@HOST --src-path /path/on/source \
                --dests "USER@HOST1,USER@HOST2" --dst-path /path/on/dest [--no-selinux]

env overrides:
  SOURCE, SRC_PATH, DESTS, DST_PATH, SELINUX_RELABEL=0|1

examples:
  rsync_path.sh \
    --source ngen-pw-user@10.105.105.216 \
    --src-path /ngencerf-app/aws \
    --dests "ngen-pw-user@10.203.97.234,ngen-pw-user@10.105.109.254,ngen-pw-user@10.203.110.172" \
    --dst-path /ngencerf-app/aws
USAGE
    exit 1
}

# parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --src-path) SRC_PATH="$2"; shift 2 ;;
        --dests) DESTS="$2"; shift 2 ;;
        --dst-path) DST_PATH="$2"; shift 2 ;;
        --no-selinux) SELINUX_RELABEL=0; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1"; usage ;;
    esac
done

# validate inputs
[[ -n "${SOURCE}" ]] || { echo "error: --source required"; usage; }
[[ -n "${SRC_PATH}" ]] || { echo "error: --src-path required"; usage; }
[[ -n "${DESTS}" ]] || { echo "error: --dests required"; usage; }
[[ -n "${DST_PATH}" ]] || { echo "error: --dst-path required"; usage; }

# normalize dests into an array (split on commas or spaces)
DESTS_CLEAN="$(echo "$DESTS" | tr ',' ' ')"
read -r -a DEST_ARR <<< "$DESTS_CLEAN"

# create local temp dir
TMPDIR="$(mktemp -d -p "$HOME" copytmp.XXXXXX)"
chmod 700 "$TMPDIR"

echo "[1/3] pulling from ${SOURCE}:${SRC_PATH}/ -> $TMPDIR/"
rsync -av \
    --rsync-path="sudo rsync" \
    "${SOURCE}:${SRC_PATH}/" "$TMPDIR/"

echo "[2/3] pushing to destinations..."
for h in "${DEST_ARR[@]}"; do
    echo "  -> ${h}:${DST_PATH}"
    ssh "$h" "sudo install -d -m 700 -o root -g root '$DST_PATH'"
    rsync -av --delete \
        --chmod=F600,D700 \
        --chown=root:root \
        --rsync-path='sudo rsync' \
        "$TMPDIR/" "${h}:${DST_PATH}/"
    if [[ "$SELINUX_RELABEL" -eq 1 ]]; then
        ssh "$h" "sudo restorecon -R '$DST_PATH' || true"
    fi
done

echo "[3/3] cleaning up $TMPDIR"
rm -rf "$TMPDIR"
echo "done."
