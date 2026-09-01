#!/usr/bin/env bash
set -euo pipefail

# overridable container path and ngen binary path inside container
NGEN_CONTAINER="${NGEN_CONTAINER:-/ngencerf-app/singularity/nwm-cal-mgr.sif}"
NGEN_BINARY="${NGEN_BINARY:-/ngen-app/ngen/cmake_build/ngen}"

# test if singularity file and ngen binary are available
command -v singularity >/dev/null || { echo "error: singularity not found in PATH" >&2; exit 127; }
[ -r "$NGEN_CONTAINER" ] || { echo "error: sif not found or unreadable: $NGEN_CONTAINER" >&2; exit 126; }
singularity exec "$NGEN_CONTAINER" test -r "$NGEN_BINARY" \
  || { echo "error: ngen binary not found/readable in image: $NGEN_BINARY" >&2; exit 126; }

# always bind current working directory
bind_args=(--bind "$PWD:$PWD" --pwd "$PWD")

# track already-added binds
declare -A _seen=()

# function to add a bind mount if the host path exists and hasn't been added yet
add_bind() {
  local host="$1" cont="${2:-$1}"
  [[ -z "$host" ]] && return 0
  if [[ -d "$host" && -z "${_seen[$host]:-}" ]]; then
    bind_args+=(--bind "$host:$cont")
    _seen[$host]=1
  fi
}

# function to decide if an arg is a path (absolute or relative files or dirs)
is_path_arg() {
  local a="$1"
  [[ -z "$a" || "$a" == "all" ]] && return 1
  [[ "$a" == -* ]] && return 1
  if [[ "$a" == *,* && "$a" != *"/"* ]]; then return 1; fi
  [[ "$a" == *"/"* ]] && return 0
  local abs="$PWD/$a"; local parent; parent=$(dirname -- "$abs")
  [[ -d "$parent" ]] && return 0
  return 1
}

# scan args; bind parent dirs of any path-like args
missing_parents=()
for arg in "$@"; do
  if is_path_arg "$arg"; then
    if [[ "$arg" = /* ]]; then parent=$(dirname -- "$arg"); else parent=$(dirname -- "$PWD/$arg"); fi
    [[ -d "$parent" ]] && add_bind "$parent" || missing_parents+=("$parent")
  fi
done

# run ngen command inside singularity container
exec singularity exec "${bind_args[@]}" "$NGEN_CONTAINER" "$NGEN_BINARY" "$@"
