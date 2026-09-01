#!/usr/bin/env bash
set -euo pipefail

AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/ngencerf-app/aws/credentials}"

# prompt for variables
prompt() {
  local var="$1" msg="$2" def="${3:-}" silent="${4:-}" cur="${!var:-}" input
  [ -n "${cur:-}" ] && return 0
  local p="$msg"; [ -n "$def" ] && p="$msg [default: $def]"
  if [ "$silent" = "silent" ]; then read -r -s -p "$p: " input; echo
  else read -r -p "$p: " input
  fi
  if [ -z "${input:-}" ] && [ -n "$def" ]; then printf -v "$var" "%s" "$def"
  else printf -v "$var" "%s" "$input"
  fi
  export "$var"
}

# prompt for buckets
prompt HF_BUCKET      "hydrofabric S3 bucket name" "ngwpc-hydrofabric"
prompt FORCING_BUCKET "forcing S3 bucket name"     "ngwpc-forcing"
prompt COASTAL_BUCKET "coastal S3 bucket name"     "ngwpc-coastal"

# prompt for mount dirs
prompt HF_MOUNT_DIR      "local dir for hydrofabric" "/ngwpc-hydrofabric"
prompt FORCING_MOUNT_DIR "local dir for forcing"     "/ngwpc-forcing"
prompt COASTAL_MOUNT_DIR "local dir for coastal"     "/ngwpc-coastal"

# try to find an existing, root-readable AWS credentials file
find_existing_creds() {
  local p

  # 1) respect env if it already points to a readable file (as root)
  if sudo test -r "$AWS_SHARED_CREDENTIALS_FILE"; then
    echo "$AWS_SHARED_CREDENTIALS_FILE"; return 0
  fi

  return 1
}

CREDS_FOUND_PATH=""
if CREDS_FOUND_PATH="$(find_existing_creds)"; then
  echo "using existing AWS creds at: $CREDS_FOUND_PATH"
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FOUND_PATH"
else
  # fall back: prompt and create the credentials file (owned by root, 600)
  echo "aws creds will be written to: $AWS_SHARED_CREDENTIALS_FILE"
  prompt AWS_ACCESS_KEY_ID     "AWS Access Key ID"
  prompt AWS_SECRET_ACCESS_KEY "AWS Secret Access Key" "" "silent"

  sudo mkdir -p "$(dirname "$AWS_SHARED_CREDENTIALS_FILE")"
  sudo install -m 600 /dev/null "$AWS_SHARED_CREDENTIALS_FILE"
  sudo tee "$AWS_SHARED_CREDENTIALS_FILE" >/dev/null <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  echo "error: no existing AWS creds found; please mount s3 buckets manually." >&2
fi

# check if mount-s3 is installed
command -v mount-s3 >/dev/null || { echo "error: mount-s3 not found."; exit 1; }

# create mountpoints
sudo mkdir -p "$HF_MOUNT_DIR" "$FORCING_MOUNT_DIR" "$COASTAL_MOUNT_DIR"

# check if mountpoint is empty
is_empty_dir() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# mount s3 bucket to target dir
mount_pair() {
  local bucket="$1" target="$2"
  if findmnt -rn -T "$target" >/dev/null 2>&1; then
    if is_empty_dir "$target"; then
      echo "mounted but empty → remounting $target"
      sudo umount -l "$target" 2>/dev/null || sudo fusermount -u "$target" 2>/dev/null || true
    else
      echo "skip: $target already mounted"
      return 0
    fi
  fi
  echo "mounting s3://$bucket -> $target"
  sudo AWS_SHARED_CREDENTIALS_FILE="$AWS_SHARED_CREDENTIALS_FILE" \
    mount-s3 --allow-other --read-only "$bucket" "$target"
}

# mount s3 buckets
mount_pair "$HF_BUCKET"      "$HF_MOUNT_DIR"
mount_pair "$FORCING_BUCKET" "$FORCING_MOUNT_DIR"
mount_pair "$COASTAL_BUCKET" "$COASTAL_MOUNT_DIR"

# verify mounts
verify_mount() {
  local target="$1"
  if findmnt -rn -T "$target" >/dev/null 2>&1 && ! is_empty_dir "$target"; then
    echo "ok: $target is mounted and has contents"
  else
    echo "error: $target is mounted but empty or not mounted. Check creds/permissions." >&2
    return 1
  fi
}

# verify all mounts
fail=0
verify_mount "$HF_MOUNT_DIR"      || fail=1
verify_mount "$FORCING_MOUNT_DIR" || fail=1
verify_mount "$COASTAL_MOUNT_DIR" || fail=1
[ "$fail" -eq 0 ] || exit 1

echo "s3 buckets mounted:"
echo "  $HF_BUCKET -> $HF_MOUNT_DIR"
echo "  $FORCING_BUCKET -> $FORCING_MOUNT_DIR"
echo "  $COASTAL_BUCKET -> $COASTAL_MOUNT_DIR"
