#!/bin/bash

set -e
set -o pipefail

# Trap errors to provide better error reporting
trap 'handle_error $? $LINENO' ERR

handle_error() {
    local exit_code=$1
    local line_number=$2

    echo ""
    echo "=========================================="
    echo "BUILD FAILED"
    echo "=========================================="
    echo "Error occurred at line: $line_number"
    echo "Exit code: $exit_code"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Check the build output above for details."
    echo "Log file: ${LOGFILE:-build_cluster.log}"
    echo "=========================================="
    echo ""

    # Exit cleanly without killing the parent shell
    exit $exit_code
}

# ==============================================================================
# NGEN/NGENCERF Build Script
# ==============================================================================
#
# This script builds and symlinks Singularity containers for selected NGEN repos.
# It supports both interactive use and non-interactive (automated) use via CLI.
#
# ------------------------------------------------------------------------------
# USAGE EXAMPLES
# ------------------------------------------------------------------------------
#
# Interactive mode (will prompt for build type, repos, and optional per-repo source):
#   ./build_cluster.sh
#
# Development build (non-interactive, builds ngen and nwm-cal-mgr):
#   ./build_cluster.sh --build-type=development ngen nwm-cal-mgr
#
# Build all supported repos (non-interactive):
#   ./build_cluster.sh --build-type=development all
#
# Build for release (will still prompt for tags):
#   ./build_cluster.sh --build-type=release ngen nwm-cal-mgr nwm-verf
#
# Feature build (mirrors development but uses the feature branch
# and tags images as :feature):
#   ./build_cluster.sh --build-type=feature ngen nwm-cal-mgr
#
# Per-repo image source (build|pull), applies to dev/rc/release:
#   ./build_cluster.sh --build-type=development \
#     --source=ngen:build --source=nwm-cal-mgr:build ngen nwm-cal-mgr
#   ./build_cluster.sh --build-type=release \
#     --source-default=build ngen nwm-cal-mgr ngen-forcing nwm-fcst-mgr nwm-verf
#
# ------------------------------------------------------------------------------
# ARGUMENTS
# ------------------------------------------------------------------------------
#
#   --build-type=TYPE        One of: development, release, feature
#   --source=REPO:MODE       For REPO in {ngen, nwm-cal-mgr, ngen-bmi-forcing, ngen-sfincs-forcing,
#                            ngen-coastal, nwm-verf, nwm-fcst-mgr}, MODE is build or pull. Can be repeated.
#                            ngen-forcing can be used as shorthand for all forcing images.
#   --source-default=MODE    Global default (build|pull) for the above repos (optional).
#   --branch=REPO:REF        Specify a branch or commit hash for a specific repo (optional).
#                            Example: --branch=ngen:feature/my-feature or --branch=ngen:a1b2c3d
#   --tag=REPO:TAG          For feature builds: specify tag to pull for REPO (only used when pulling).
#                            Example: --tag=ngen-forcing:latest
#   repo names               List of repos to build (space-separated on CLI), or use "all"
#                            In interactive mode, repos can be space or comma-separated
#
# Supported repos:
#   ngencerf-server, ngencerf-ui, ngencerf-docker, ngen, nwm-cal-mgr, ngen-forcing,
#   ngen-bmi-forcing, ngen-sfincs-forcing, ngen-coastal, nwm-fcst-mgr, nwm-verf
#
# ngen-forcing expands to all individual forcing images (ngen-bmi-forcing, ngen-sfincs-forcing, ngen-coastal).
# Individual forcing images can be specified separately.
# Feature builds support commit hashes in addition to branch names.
#
# Notes:
# - If no arguments are passed, the script runs interactively.
# - If "all" is passed as a repo, it expands to all supported repos.
# - For release, tag prompts will appear.
#
# ==============================================================================

# --- BASE DIRECTORY SETUP (paths only, actual creation happens after arg parsing) ---
BASE_PATH="/ngencerf-app"
SINGULARITY_DIR="${BASE_PATH}/singularity"

# Branch/ref selection for building - now per-repo
declare -A REPO_BRANCHES   # map: repo -> ref (branch or commit hash)
BRANCH_DEFAULT=""          # global default ref (optional)

REPOS=(
    "ngencerf-ui"
    "ngencerf-server"
    "ngencerf-docker"
    "ngen"
    "nwm-cal-mgr"
    "ngen-forcing"
    "nwm-fcst-mgr"
    "nwm-verf"
)
# individual forcing image repos (ngen-forcing expands to these)
FORCING_IMAGE_REPOS=("ngen-bmi-forcing" "ngen-sfincs-forcing" "ngen-coastal")
REGISTRY="ghcr.io/ngwpc"

BUILD_TYPE=""
SELECTED_REPOS=()
PROMPTED_FOR_CORE_INPUT=false

# repos with selectable image source (build vs pull)
TARGET_REPOS_FOR_SOURCE=("ngen" "nwm-cal-mgr" "ngen-bmi-forcing" "ngen-sfincs-forcing" "ngen-coastal" "nwm-verf" "nwm-fcst-mgr")
declare -A IMAGE_SOURCE   # map: repo -> build|pull
IMAGE_SOURCE_DEFAULT=""
declare -A IMAGE_FETCHED  # map: repo -> true when image already built/pulled

# Dependency image tags for build arguments
declare -A DEPENDENCY_TAGS  # map: dependent_repo -> dependency_tag
# e.g., DEPENDENCY_TAGS["ngen"]="feature"  # ngen will use ngen-bmi-forcing:feature
#       DEPENDENCY_TAGS["nwm-cal-mgr"]="v1.0"  # nwm-cal-mgr will use ngen:v1.0

# Tags for release/feature builds
declare -A TAGS  # map: repo -> tag

# map repo -> "docker_image|sif_name" (space-separated for multiples)
images_for_repo() {
    local repo="$1"
    case "$repo" in
        ngen)            echo "ngen|ngen" ;;
        ngencerf-ui)     echo "" ;;
        ngencerf-server) echo "" ;;
        ngencerf-docker) echo "" ;;
        nwm-cal-mgr)     echo "nwm-cal-mgr|nwm-cal-mgr" ;;
        ngen-bmi-forcing) echo "ngen-bmi-forcing|ngen-bmi-forcing" ;;
        ngen-sfincs-forcing) echo "ngen-sfincs-forcing|ngen-sfincs-forcing" ;;
        ngen-coastal)    echo "ngen-coastal|ngen-coastal" ;;
        nwm-fcst-mgr)    echo "nwm-fcst-mgr|nwm-fcst-mgr" ;;
        nwm-verf)        echo "nwm-verf|nwm-verf" ;;
        *)               echo "$repo|$repo" ;;
    esac
}

# function to determine if a repo has an associated SIF to build
# ngen and ngen-bmi-forcing are built as Docker images only (consumed via FROM
# by nwm-cal-mgr/nwm-fcst-mgr); at runtime the ngen binary and forcing engine
# are accessed through nwm-cal-mgr.sif, so no standalone SIF is produced.
repo_has_sif() {
    case "$1" in
        ngencerf-server|ngencerf-ui|ngencerf-docker|ngen|ngen-bmi-forcing) return 1 ;;
        *) return 0 ;;
    esac
}

# map repo name to its git directory (forcing image repos share ngen-forcing)
repo_to_directory() {
    case "$1" in
        ngen-bmi-forcing|ngen-sfincs-forcing|ngen-coastal) echo "ngen-forcing" ;;
        *) echo "$1" ;;
    esac
}

# set workflow (build or pull) default for repos with SIF (overridden by --source-default/--source)
set_image_source_defaults() {
    # initialize all to empty
    for r in "${TARGET_REPOS_FOR_SOURCE[@]}"; do IMAGE_SOURCE["$r"]=''; done

    # for feature builds, force all to "build" (no pulling allowed)
    if [[ "$BUILD_TYPE" == "feature" ]]; then
        for r in "${TARGET_REPOS_FOR_SOURCE[@]}"; do IMAGE_SOURCE["$r"]="build"; done
        return
    fi

    if [[ "$BUILD_TYPE" == "development" ]]; then
        IMAGE_SOURCE["ngen"]="build"
        IMAGE_SOURCE["ngen-bmi-forcing"]="build"
        IMAGE_SOURCE["ngen-sfincs-forcing"]="build"
        IMAGE_SOURCE["ngen-coastal"]="build"
    else
        # for release builds, default to "build" for all repos
        # (user can override with --source or --source-default flags)
        IMAGE_SOURCE["ngen"]="build"
        IMAGE_SOURCE["ngen-bmi-forcing"]="build"
        IMAGE_SOURCE["ngen-sfincs-forcing"]="build"
        IMAGE_SOURCE["ngen-coastal"]="build"
    fi
    IMAGE_SOURCE["nwm-cal-mgr"]="build"
    IMAGE_SOURCE["nwm-fcst-mgr"]="build"
    IMAGE_SOURCE["nwm-verf"]="build"

    if [[ -n "$IMAGE_SOURCE_DEFAULT" ]]; then
        for r in "${TARGET_REPOS_FOR_SOURCE[@]}"; do IMAGE_SOURCE["$r"]="$IMAGE_SOURCE_DEFAULT"; done
    fi
}

# --- Help function ---
show_help() {
    cat <<'EOF'
NGEN/NGENCERF Build Script

This script builds and symlinks Singularity containers for selected NGEN repos.
It supports both interactive use and non-interactive (automated) use via CLI.

USAGE:
  ./build_cluster.sh [OPTIONS] [REPOS...]

OPTIONS:
  --build-type=TYPE          One of: development, release, feature
  --branch=REPO:REF          Specify a branch or commit hash for a specific repo. Can be repeated.
                             Example: --branch=ngen:feature/my-feature
                             Example: --branch=ngen:a1b2c3d (commit hash)
  --branch-default=REF       Global default branch/commit for all repos (optional)
  --source=REPO:MODE         For REPO in {ngen, nwm-cal-mgr, ngen-bmi-forcing, ngen-sfincs-forcing,
                             ngen-coastal, nwm-verf, nwm-fcst-mgr}, MODE is build or pull. Can be repeated.
                             Use ngen-forcing as shorthand for all forcing images.
  --source-default=MODE      Global default (build|pull) for the above repos (optional)
  --tag=REPO:TAG             For feature builds: specify tag to pull for REPO (only used when pulling).
                             Example: --tag=ngen-forcing:latest
  --ngen-forcing-tag=TAG     For feature builds: specify ngen-forcing tag for ngen to use as build arg
  --ngen-tag=TAG             For feature builds: specify ngen tag for nwm-cal-mgr/nwm-fcst-mgr to use
  --help, -h                 Show this help message and exit

REPOS:
  Supported repos: ngencerf-server, ngencerf-ui, ngencerf-docker, ngen, nwm-cal-mgr,
                   ngen-forcing, ngen-bmi-forcing, ngen-sfincs-forcing, ngen-coastal, nwm-fcst-mgr, nwm-verf
  ngen-forcing expands to all forcing images (ngen-bmi-forcing, ngen-sfincs-forcing, ngen-coastal)
  Individual forcing images can be specified separately
  Only ngen-bmi-forcing triggers downstream builds (ngen, nwm-cal-mgr, nwm-fcst-mgr)
  Use "all" to build all supported repos

EXAMPLES:
  Interactive mode (will prompt for build type, repos, refs, and sources):
    ./build_cluster.sh

  Development build with default branches:
    ./build_cluster.sh --build-type=development ngen nwm-cal-mgr

  Development build with custom refs per repo:
    ./build_cluster.sh --build-type=development \
      --branch=ngen:feature/new-hydro --branch=nwm-cal-mgr:bugfix/123 \
      ngen nwm-cal-mgr

  Development build with global default ref:
    ./build_cluster.sh --build-type=development --branch-default=my-feature \
      ngen nwm-cal-mgr ngen-forcing

  Build all repos with custom ref and source options:
    ./build_cluster.sh --build-type=development \
      --branch-default=feature/test \
      --branch=ngen:main \
      --source=ngen:pull --source-default=build \
      all

  Build for release (will still prompt for tags):
    ./build_cluster.sh --build-type=release ngen nwm-cal-mgr nwm-verf

  Feature build:
    ./build_cluster.sh --build-type=feature ngen nwm-cal-mgr

  Feature build with custom dependency tags:
    ./build_cluster.sh --build-type=feature \
      --ngen-forcing-tag=latest --ngen-tag=development \
      --source=ngen:build --source=nwm-cal-mgr:build \
      ngen-forcing ngen nwm-cal-mgr

  Feature build with commit hash:
    ./build_cluster.sh --build-type=feature \
      --branch=ngen:a1b2c3d4e5f6 \
      ngen nwm-cal-mgr

  Build only BMI forcing (no sfincs/coastal), triggering downstream builds:
    ./build_cluster.sh --build-type=development ngen-bmi-forcing

  Build only coastal forcing (no downstream builds triggered):
    ./build_cluster.sh --build-type=development ngen-coastal

NOTES:
  - If no arguments are passed, the script runs interactively
  - If "all" is passed as a repo, it expands to all supported repos
  - ngen-forcing expands to ngen-bmi-forcing + ngen-sfincs-forcing + ngen-coastal
  - Only downstream dependencies are auto-added (not upstream)
  - For release builds, tag prompts will appear
  - Feature builds support commit hashes in addition to branch names
  - Ref priority: --branch=REPO:REF > --branch-default > build-type default
  - Logs are written to: ${SINGULARITY_DIR}/build_cluster_<timestamp>.log
EOF
}

# --- Parse args ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
            ;;
            --build-type=*)
                BUILD_TYPE="${1#*=}"
            ;;
            --build-type)
                shift; BUILD_TYPE="$1"
            ;;
            --branch=*)
                local kv="${1#*=}"
                local repo="${kv%%:*}"
                local branch="${kv##*:}"
                if [[ -z "$branch" ]]; then
                    echo "Error: --branch '${kv}' must specify a branch (format: REPO:BRANCH)"; exit 1
                fi
                # ngen-forcing is a shorthand for all individual forcing image repos
                if [[ "$repo" == "ngen-forcing" ]]; then
                    for fr in "${FORCING_IMAGE_REPOS[@]}"; do
                        REPO_BRANCHES["$fr"]="$branch"
                    done
                    # also set for the repo-level name (used for git directory operations)
                    REPO_BRANCHES["ngen-forcing"]="$branch"
                elif [[ " ${REPOS[*]} " =~ " ${repo} " ]] || [[ " ${FORCING_IMAGE_REPOS[*]} " =~ " ${repo} " ]]; then
                    REPO_BRANCHES["$repo"]="$branch"
                else
                    echo "Error: --branch targets unsupported repo '${repo}'. Allowed: ${REPOS[*]} ${FORCING_IMAGE_REPOS[*]}"; exit 1
                fi
            ;;
            --branch-default=*)
                BRANCH_DEFAULT="${1#*=}"
                if [[ -z "$BRANCH_DEFAULT" ]]; then
                    echo "Error: --branch-default requires a value"; exit 1
                fi
            ;;
            --branch-default)
                shift
                if [[ -z "$1" || "$1" == -* ]]; then
                    echo "Error: --branch-default requires a value"; exit 1
                fi
                BRANCH_DEFAULT="$1"
            ;;
            --source-default=*)
                IMAGE_SOURCE_DEFAULT="${1#*=}" # build|pull
                if [[ "$IMAGE_SOURCE_DEFAULT" != "build" && "$IMAGE_SOURCE_DEFAULT" != "pull" ]]; then
                    echo "Error: --source-default must be 'build' or 'pull', got '${IMAGE_SOURCE_DEFAULT}'"; exit 1
                fi
            ;;
            --source=*)
                local kv="${1#*=}"
                local repo="${kv%%:*}"
                local mode="${kv##*:}"
                if [[ "$mode" != "build" && "$mode" != "pull" ]]; then
                    echo "Error: --source '${kv}' must be build or pull."; exit 1
                fi
                # ngen-forcing is a shorthand for all individual forcing image repos
                if [[ "$repo" == "ngen-forcing" ]]; then
                    for fr in "${FORCING_IMAGE_REPOS[@]}"; do
                        IMAGE_SOURCE["$fr"]="$mode"
                    done
                elif [[ " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]]; then
                    IMAGE_SOURCE["$repo"]="$mode"
                else
                    echo "Error: --source targets unsupported repo '${repo}'. Allowed: ngen-forcing ${TARGET_REPOS_FOR_SOURCE[*]}"; exit 1
                fi
            ;;
            --tag=*)
                local kv="${1#*=}"
                local repo="${kv%%:*}"
                local tag="${kv##*:}"
                if [[ -z "$tag" ]]; then
                    echo "Error: --tag '${kv}' must specify a tag (format: REPO:TAG)"; exit 1
                fi
                # ngen-forcing is a shorthand for all individual forcing image repos
                if [[ "$repo" == "ngen-forcing" ]]; then
                    for fr in "${FORCING_IMAGE_REPOS[@]}"; do
                        TAGS["$fr"]="$tag"
                    done
                elif [[ " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]]; then
                    TAGS["$repo"]="$tag"
                else
                    echo "Error: --tag targets unsupported repo '${repo}'. Allowed: ngen-forcing ${TARGET_REPOS_FOR_SOURCE[*]}"; exit 1
                fi
            ;;
            --ngen-forcing-tag=*)
                local tag="${1#*=}"
                if [[ -z "$tag" ]]; then
                    echo "Error: --ngen-forcing-tag requires a value"; exit 1
                fi
                DEPENDENCY_TAGS["ngen"]="$tag"
            ;;
            --ngen-tag=*)
                local tag="${1#*=}"
                if [[ -z "$tag" ]]; then
                    echo "Error: --ngen-tag requires a value"; exit 1
                fi
                DEPENDENCY_TAGS["nwm-cal-mgr"]="$tag"
                DEPENDENCY_TAGS["nwm-fcst-mgr"]="$tag"
            ;;
            -*)
                echo "Unknown option: $1"; exit 1
            ;;
            *)
                SELECTED_REPOS+=("$1")
            ;;
        esac
        shift
    done
}

parse_args "$@"

# validate BUILD_TYPE if provided via CLI
if [[ -n "$BUILD_TYPE" ]] && [[ "$BUILD_TYPE" != "development" ]] && [[ "$BUILD_TYPE" != "release" ]] && [[ "$BUILD_TYPE" != "feature" ]]; then
    echo "Error: Invalid --build-type '${BUILD_TYPE}'. Must be one of: development, release, feature"
    exit 1
fi

# validate that branch arguments are not used with development build type
if [[ "$BUILD_TYPE" == "development" ]]; then
    if [[ -n "$BRANCH_DEFAULT" ]]; then
        echo "Error: --branch-default cannot be used with --build-type=development"
        echo "Development builds always use the 'development' branch for all repos."
        exit 1
    fi
    if [[ ${#REPO_BRANCHES[@]} -gt 0 ]]; then
        echo "Error: --branch cannot be used with --build-type=development"
        echo "Development builds always use the 'development' branch for all repos."
        exit 1
    fi
fi

# validate dependency tags are only used with feature build type
if [[ ${#DEPENDENCY_TAGS[@]} -gt 0 && "$BUILD_TYPE" != "feature" ]]; then
    echo "Error: --ngen-forcing-tag and --ngen-tag can only be used with --build-type=feature"
    exit 1
fi

# --- Create directories and setup logging (after arg parsing to allow --help to work) ---
mkdir -p "$SINGULARITY_DIR"
LOGFILE="${SINGULARITY_DIR}/build_cluster_$(date -u +"%Y-%m-%dT%H:%M:%SZ").log"
exec > >(tee -i "$LOGFILE") 2>&1

# --- Interactive prompts if needed ---
if [[ -z "$BUILD_TYPE" && -t 0 ]]; then
    echo "Select build type:"
    echo "1) development"
    echo "2) release"
    echo "3) feature"
    read -p "Enter number [1-3]: " build_choice || { echo "Error reading input, exiting."; exit 1; }
    case $build_choice in
        1) BUILD_TYPE="development" ;;
        2) BUILD_TYPE="release" ;;
        3) BUILD_TYPE="feature" ;;
        *) echo "Invalid choice, exiting."; exit 1 ;;
    esac
    PROMPTED_FOR_CORE_INPUT=true
fi

if [[ ${#SELECTED_REPOS[@]} -eq 0 && -t 0 ]]; then
    echo "Available repos: ${REPOS[*]}"
    read -p "Enter repos to build (space or comma-separated, or press Enter for all): " repos_input || { echo "Error reading input, exiting."; exit 1; }
    # if user pressed Enter without typing anything, select all repos
    if [[ -z "$repos_input" ]]; then
        SELECTED_REPOS=("${REPOS[@]}")
        echo "All repos selected: ${SELECTED_REPOS[*]}"
    else
        # normalize input: replace commas with spaces, then split into array
        repos_input="${repos_input//,/ }"
        read -ra SELECTED_REPOS <<< "$repos_input"
    fi
    PROMPTED_FOR_CORE_INPUT=true
fi

if [[ -z "$BUILD_TYPE" || ${#SELECTED_REPOS[@]} -eq 0 ]]; then
    echo "Error: build type and at least one repo must be provided."; exit 1
fi

set_image_source_defaults

# expand 'all'
if [[ " ${SELECTED_REPOS[*]} " =~ " all " ]]; then
    echo "'all' specified — building all available repos."
    SELECTED_REPOS=("${REPOS[@]}")
    echo "Repos to build: ${SELECTED_REPOS[*]}"
fi

# validate repos (accept both REPOS and individual FORCING_IMAGE_REPOS)
INVALID_REPOS=()
for repo in "${SELECTED_REPOS[@]}"; do
    if [[ ! " ${REPOS[*]} " =~ " $repo " ]] && [[ ! " ${FORCING_IMAGE_REPOS[*]} " =~ " $repo " ]]; then
        INVALID_REPOS+=("$repo")
    fi
done
if [[ ${#INVALID_REPOS[@]} -gt 0 ]]; then
    echo "Error: Invalid repo(s): ${INVALID_REPOS[*]}"
    echo "Allowed repos are: ${REPOS[*]} ${FORCING_IMAGE_REPOS[*]}"
    exit 1
fi

# expand ngen-forcing to individual forcing image repos
if [[ " ${SELECTED_REPOS[*]} " =~ " ngen-forcing " ]]; then
    echo "'ngen-forcing' selected — expanding to all forcing images: ${FORCING_IMAGE_REPOS[*]}"
    local_new_selected=()
    for r in "${SELECTED_REPOS[@]}"; do
        if [[ "$r" == "ngen-forcing" ]]; then
            for fr in "${FORCING_IMAGE_REPOS[@]}"; do
                # avoid duplicates
                if [[ ! " ${local_new_selected[*]} " =~ " ${fr} " ]]; then
                    local_new_selected+=("$fr")
                fi
            done
        else
            local_new_selected+=("$r")
        fi
    done
    SELECTED_REPOS=("${local_new_selected[@]}")
    # transfer ngen-forcing branch/tag settings to individual repos if not already set
    if [[ -n "${REPO_BRANCHES[ngen-forcing]:-}" ]]; then
        for fr in "${FORCING_IMAGE_REPOS[@]}"; do
            if [[ -z "${REPO_BRANCHES[$fr]:-}" ]]; then
                REPO_BRANCHES["$fr"]="${REPO_BRANCHES[ngen-forcing]}"
            fi
        done
    fi
    if [[ -n "${TAGS[ngen-forcing]:-}" ]]; then
        for fr in "${FORCING_IMAGE_REPOS[@]}"; do
            if [[ -z "${TAGS[$fr]:-}" ]]; then
                TAGS["$fr"]="${TAGS[ngen-forcing]}"
            fi
        done
    fi
    echo "Expanded repos: ${SELECTED_REPOS[*]}"
fi

# display summary and optional interactive per-repo source/branch selection
echo "Build type selected: $BUILD_TYPE"
echo "Selected repos: ${SELECTED_REPOS[*]}"

if [[ -t 0 ]]; then
    # ref prompting for feature builds (only for feature builds in interactive mode)
    if [[ "$BUILD_TYPE" == "feature" ]]; then
        for repo in "${SELECTED_REPOS[@]}"; do
            if [[ -z "${REPO_BRANCHES[$repo]:-}" ]]; then
                read -p "Enter ${repo} ref (branch or commit hash): " ans || { echo "Error reading input, exiting."; exit 1; }
                # require a ref (no default) for feature builds
                while [[ -z "$ans" ]]; do
                    echo "Error: Ref cannot be empty for feature builds"
                    read -p "Enter ${repo} ref (branch or commit hash): " ans || { echo "Error reading input, exiting."; exit 1; }
                done
                REPO_BRANCHES["$repo"]="$ans"
            fi
        done
    fi
fi

# get the ref to use for a specific repo
# priority: REPO_BRANCHES[repo] > BRANCH_DEFAULT > build_type_default
get_repo_branch() {
    local repo="$1"
    local build_type_default="$2"

    # check if repo has specific branch set
    if [[ -n "${REPO_BRANCHES[$repo]:-}" ]]; then
        echo "${REPO_BRANCHES[$repo]}"
    # check if global default is set
    elif [[ -n "$BRANCH_DEFAULT" ]]; then
        echo "$BRANCH_DEFAULT"
    # fall back to build type default
    else
        echo "$build_type_default"
    fi
}

# get the Docker tag to use for a repo based on build type
# for feature builds, returns the branch name (sanitized)
# for development builds, returns "latest"
# for release builds, returns the tag from TAGS array
get_docker_tag_for_repo() {
    local repo="$1"
    local build_type="$2"

    if [[ "$build_type" == "development" ]]; then
        echo "latest"
    elif [[ "$build_type" == "feature" ]]; then
        # get branch name for this repo
        local branch="${REPO_BRANCHES[$repo]:-}"
        if [[ -z "$branch" ]]; then
            echo "Error: No branch specified for $repo in feature build" >&2
            exit 1
        fi
        # sanitize branch name for Docker tag (replace / with -)
        echo "${branch//\//-}"
    else
        # release build
        echo "${TAGS[$repo]:-}"
    fi
}

# check if a git reference is a commit hash (vs a branch/tag name)
# returns 0 (true) if it's a commit hash, 1 (false) otherwise
is_commit_hash() {
    local ref="$1"
    # check if it's a valid hex string of 7-40 characters (short or full SHA)
    if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
        return 0
    fi
    return 1
}

# prompt for dependency tags/branches in interactive mode
# this is used for release and feature builds to collect dependency information
prompt_dependency_tags() {
    local build_type="$1"

    # only applicable to feature and release builds
    [[ "$build_type" != "feature" && "$build_type" != "release" ]] && return 0
    [[ ! -t 0 ]] && return 0  # not interactive

    if [[ "$build_type" == "release" ]]; then
        # for release builds, prompt for dependency tags only if not already set
        # ngen depends on ngen-bmi-forcing (only when ngen is being built, not pulled)
        if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]] && [[ "${IMAGE_SOURCE[ngen]:-build}" == "build" ]] && [[ -z "${TAGS[ngen-bmi-forcing]:-}" ]]; then
            read -p "Enter ngen-bmi-forcing tag (used by ngen): " TAGS[ngen-bmi-forcing] || { echo "Error reading input, exiting."; exit 1; }
        fi

        # nwm-cal-mgr and nwm-fcst-mgr depend on ngen
        if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]] || [[ " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
            if [[ -z "${TAGS[ngen]:-}" ]]; then
                read -p "Enter ngen tag (used by nwm-cal-mgr/nwm-fcst-mgr): " TAGS[ngen] || { echo "Error reading input, exiting."; exit 1; }
            fi
        fi

        # nwm-verf depends on nwm-eval-mgr
        if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-verf " ]] && [[ -z "${TAGS[nwm-eval-mgr]:-}" ]]; then
            read -p "Enter nwm-eval-mgr tag (used by nwm-verf): " TAGS[nwm-eval-mgr] || { echo "Error reading input, exiting."; exit 1; }
        fi
    elif [[ "$build_type" == "feature" ]]; then
        # for feature builds, prompt for dependency branches OR existing tags
        # ngen depends on ngen-bmi-forcing
        if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]] && [[ -z "${DEPENDENCY_TAGS[ngen]:-}" ]] && [[ -z "${REPO_BRANCHES[ngen-bmi-forcing]:-}" ]]; then
            # Check if ngen-bmi-forcing is also being built (in which case we'll use the branch)
            if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-bmi-forcing " ]]; then
                # ngen-bmi-forcing is being built, so we'll use its branch-derived tag
                echo "ngen-bmi-forcing will be built; ngen will use the resulting image"
            else
                # Prompt: build ngen-bmi-forcing from branch OR use existing tag
                echo "For ngen-bmi-forcing dependency (required by ngen):"
                echo "  1) Build from branch"
                echo "  2) Use existing Docker tag"
                read -p "Choose [1-2]: " choice || { echo "Error reading input, exiting."; exit 1; }
                case $choice in
                    1)
                        read -p "Enter ngen-bmi-forcing branch to build: " ans || { echo "Error reading input, exiting."; exit 1; }
                        if [[ -z "$ans" ]]; then
                            echo "Error: ngen-bmi-forcing branch is required"
                            exit 1
                        fi
                        REPO_BRANCHES["ngen-bmi-forcing"]="$ans"
                    ;;
                    2)
                        read -p "Enter ngen-bmi-forcing Docker tag to use (e.g., latest, v1.0): " ans || { echo "Error reading input, exiting."; exit 1; }
                        if [[ -z "$ans" ]]; then
                            echo "Error: ngen-bmi-forcing tag is required"
                            exit 1
                        fi
                        DEPENDENCY_TAGS["ngen"]="$ans"
                    ;;
                    *)
                        echo "Invalid choice, exiting."; exit 1
                    ;;
                esac
            fi
        fi

        # nwm-cal-mgr and nwm-fcst-mgr depend on ngen
        if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]] || [[ " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
            if [[ -z "${DEPENDENCY_TAGS[nwm-cal-mgr]:-}" ]] && [[ -z "${DEPENDENCY_TAGS[nwm-fcst-mgr]:-}" ]] && [[ -z "${REPO_BRANCHES[ngen]:-}" ]]; then
                # Check if ngen is also being built
                if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
                    # ngen is being built, so we'll use its branch-derived tag
                    echo "ngen will be built; nwm-cal-mgr/nwm-fcst-mgr will use the resulting image"
                else
                    # Prompt: build ngen from branch OR use existing tag
                    echo "For ngen dependency (required by nwm-cal-mgr/nwm-fcst-mgr):"
                    echo "  1) Build from branch"
                    echo "  2) Use existing Docker tag"
                    read -p "Choose [1-2]: " choice || { echo "Error reading input, exiting."; exit 1; }
                    case $choice in
                        1)
                            read -p "Enter ngen branch to build: " ans || { echo "Error reading input, exiting."; exit 1; }
                            if [[ -z "$ans" ]]; then
                                echo "Error: ngen branch is required"
                                exit 1
                            fi
                            REPO_BRANCHES["ngen"]="$ans"
                        ;;
                        2)
                            read -p "Enter ngen Docker tag to use (e.g., latest, v1.0): " ans || { echo "Error reading input, exiting."; exit 1; }
                            if [[ -z "$ans" ]]; then
                                echo "Error: ngen tag is required"
                                exit 1
                            fi
                            DEPENDENCY_TAGS["nwm-cal-mgr"]="$ans"
                            DEPENDENCY_TAGS["nwm-fcst-mgr"]="$ans"
                        ;;
                        *)
                            echo "Invalid choice, exiting."; exit 1
                        ;;
                    esac
                fi
            fi
        fi

        # nwm-verf depends on nwm-eval-mgr (branch)
        if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-verf " ]] && [[ -z "${DEPENDENCY_TAGS[nwm-verf]:-}" ]]; then
            read -p "Enter nwm-eval-mgr branch (used by nwm-verf): " ans || { echo "Error reading input, exiting."; exit 1; }
            if [[ -z "$ans" ]]; then
                echo "Error: nwm-eval-mgr branch is required"
                exit 1
            fi
            DEPENDENCY_TAGS["nwm-verf"]="$ans"
        fi
    fi
}

# reorder SELECTED_REPOS to respect dependency chain
# forcing images must come before ngen, ngen must come before nwm-cal-mgr/nwm-fcst-mgr
reorder_repos_by_dependency() {
    local ordered=()
    local remaining=("${SELECTED_REPOS[@]}")

    # dependency order: forcing images -> ngen -> nwm-cal-mgr/nwm-fcst-mgr -> others
    local priority_order=("ngen-bmi-forcing" "ngen-sfincs-forcing" "ngen-coastal" "ngen" "nwm-cal-mgr" "nwm-fcst-mgr")

    # first, add priority repos in order if they exist in SELECTED_REPOS
    for repo in "${priority_order[@]}"; do
        if [[ " ${remaining[*]} " =~ " ${repo} " ]]; then
            ordered+=("$repo")
            # remove from remaining (exact match only, not substring)
            local new_remaining=()
            for r in "${remaining[@]}"; do
                [[ "$r" != "$repo" ]] && new_remaining+=("$r")
            done
            remaining=("${new_remaining[@]}")
        fi
    done

    # then add any remaining repos
    for repo in "${remaining[@]}"; do
        [[ -n "$repo" ]] && ordered+=("$repo")
    done

    SELECTED_REPOS=("${ordered[@]}")
}

# auto-include DOWNSTREAM dependencies in SELECTED_REPOS based on what's selected
# Upstream dependencies are NOT auto-added (user must explicitly include them).
# DOWNSTREAM dependencies (consumers that need rebuilding):
#   - ngen-bmi-forcing is consumed by ngen, nwm-cal-mgr, nwm-fcst-mgr
#   - ngen is consumed by nwm-cal-mgr, nwm-fcst-mgr
#   - ngen-coastal has NO downstream consumers
auto_include_dependencies() {
    local added_deps=()
    # Save the originally selected repos (before auto-adding any dependencies)
    # Only these repos will trigger downstream dependency additions
    local -a originally_selected=("${SELECTED_REPOS[@]}")

    # DOWNSTREAM DEPENDENCIES: Auto-add for development and release builds, and interactive feature builds
    # For CLI feature builds, user must explicitly specify downstream repos to avoid branch ambiguity
    local skip_downstream_for_feature=false
    if [[ "$BUILD_TYPE" == "feature" && ! -t 0 ]]; then
        skip_downstream_for_feature=true
    fi

    if [[ "$skip_downstream_for_feature" != "true" ]]; then
        # if ngen-bmi-forcing was ORIGINALLY selected (not auto-added),
        # add all downstream consumers because they need to be rebuilt to pick up changes
        if [[ " ${originally_selected[@]} " =~ " ngen-bmi-forcing " ]]; then
            # Add ngen (direct consumer of ngen-bmi-forcing)
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
                SELECTED_REPOS+=("ngen")
                added_deps+=("ngen")
                echo "Auto-adding downstream dependency: ngen (consumes ngen-bmi-forcing)"
                # For feature builds, inherit branch from ngen-bmi-forcing if not already set
                if [[ "$BUILD_TYPE" == "feature" && -z "${REPO_BRANCHES[ngen]:-}" && -n "${REPO_BRANCHES[ngen-bmi-forcing]:-}" ]]; then
                    REPO_BRANCHES["ngen"]="${REPO_BRANCHES[ngen-bmi-forcing]}"
                    echo "Using branch '${REPO_BRANCHES[ngen-bmi-forcing]}' for ngen (inherited from ngen-bmi-forcing)"
                fi
            fi

            # Add nwm-cal-mgr (indirect consumer via ngen)
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]]; then
                SELECTED_REPOS+=("nwm-cal-mgr")
                added_deps+=("nwm-cal-mgr")
                echo "Auto-adding downstream dependency: nwm-cal-mgr (consumes ngen)"
            fi

            # Add nwm-fcst-mgr (indirect consumer via ngen)
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
                SELECTED_REPOS+=("nwm-fcst-mgr")
                added_deps+=("nwm-fcst-mgr")
                echo "Auto-adding downstream dependency: nwm-fcst-mgr (consumes ngen)"
            fi
        fi

        # if ngen was ORIGINALLY selected (not auto-added), add downstream consumers
        if [[ " ${originally_selected[@]} " =~ " ngen " ]]; then
            # Add nwm-cal-mgr (direct consumer of ngen)
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " nwm-cal-mgr " ]]; then
                SELECTED_REPOS+=("nwm-cal-mgr")
                added_deps+=("nwm-cal-mgr")
                echo "Auto-adding downstream dependency: nwm-cal-mgr (consumes ngen)"
            fi

            # Add nwm-fcst-mgr (direct consumer of ngen)
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " nwm-fcst-mgr " ]]; then
                SELECTED_REPOS+=("nwm-fcst-mgr")
                added_deps+=("nwm-fcst-mgr")
                echo "Auto-adding downstream dependency: nwm-fcst-mgr (consumes ngen)"
            fi
        fi

        # ngen-coastal and ngen-sfincs-forcing do NOT trigger any downstream dependencies
        # Only ngen-bmi-forcing triggers downstream builds
    fi

    # return success regardless of whether dependencies were added
    return 0
}

# validate that dependencies are satisfied
validate_dependencies() {
    local errors=()

    # for feature builds, check dependency chain
    if [[ "$BUILD_TYPE" == "feature" ]]; then
        # if ngen is being built, ensure ngen-bmi-forcing tag is available
        if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]] && [[ "${IMAGE_SOURCE[ngen]:-build}" == "build" ]]; then
            local forcing_tag="${DEPENDENCY_TAGS[ngen]:-feature}"
            # check if ngen-bmi-forcing is being built or pulled
            if [[ ! " ${SELECTED_REPOS[@]} " =~ " ngen-bmi-forcing " ]]; then
                echo "Warning: ngen will be built with NGEN_FORCING_IMAGE_TAG=${forcing_tag}, but ngen-bmi-forcing is not selected for build/pull."
                echo "         Ensure ngen-bmi-forcing:${forcing_tag} exists or select ngen-bmi-forcing for build/pull."
            fi
        fi

        # if nwm-cal-mgr/nwm-fcst-mgr is being built, ensure ngen tag is available
        for repo in "nwm-cal-mgr" "nwm-fcst-mgr"; do
            if [[ " ${SELECTED_REPOS[@]} " =~ " ${repo} " ]] && [[ "${IMAGE_SOURCE[$repo]:-build}" == "build" ]]; then
                local ngen_tag="${DEPENDENCY_TAGS[$repo]:-feature}"
                # check if ngen is being built or pulled
                if [[ ! " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
                    echo "Warning: ${repo} will be built with NGEN_IMAGE_TAG=${ngen_tag}, but ngen is not selected for build/pull."
                    echo "         Ensure ngen:${ngen_tag} exists or select ngen for build/pull."
                fi
            fi
        done
    fi
}

# auto-include missing dependencies BEFORE prompting for tags
# This ensures we prompt for all necessary repos in the correct order
auto_include_dependencies

# reorder repos to respect dependencies BEFORE prompting for tags
# This ensures tag prompts appear in the correct dependency order
reorder_repos_by_dependency

# Display the final build order so users understand the dependency chain
echo "Build order (respecting dependencies): ${SELECTED_REPOS[*]}"

# --- image source prompts (build/pull) for development and release builds ---
# This happens AFTER auto-including dependencies so all repos get prompted
if [[ -t 0 ]]; then
    # skip image source prompting unless the user was already interacting with the script
    if [[ "$BUILD_TYPE" != "feature" && "$PROMPTED_FOR_CORE_INPUT" == true ]]; then
        for repo in "${SELECTED_REPOS[@]}"; do
            if [[ " ${TARGET_REPOS_FOR_SOURCE[*]} " =~ " ${repo} " ]]; then
                default_mode="${IMAGE_SOURCE[$repo]}"
                read -p "Image source for '${repo}' [build/pull] (default: ${default_mode}): " ans || { echo "Error reading input, exiting."; exit 1; }
                if [[ -n "$ans" ]]; then
                    if [[ "$ans" != "build" && "$ans" != "pull" ]]; then
                        echo "Invalid choice '${ans}' for ${repo}. Use build or pull."; exit 1
                    fi
                    IMAGE_SOURCE["$repo"]="$ans"
                fi
            fi
        done
    fi
fi

# --- tag prompts for release and feature (when pulling) ---
if [[ "$BUILD_TYPE" == "release" ]]; then
    for repo in "${SELECTED_REPOS[@]}"; do
        case $repo in
            ngencerf-ui)
                if [[ -z "${TAGS[ngencerf-ui]:-}" ]]; then
                    read -p "Enter ngencerf-ui tag: " TAGS[ngencerf-ui] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            ngencerf-server)
                if [[ -z "${TAGS[ngencerf-server]:-}" ]]; then
                    read -p "Enter ngencerf-server tag: " TAGS[ngencerf-server] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            ngencerf-docker)
                if [[ -z "${TAGS[ngencerf-docker]:-}" ]]; then
                    read -p "Enter ngencerf-docker tag: " TAGS[ngencerf-docker] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            ngen-bmi-forcing)
                if [[ -z "${TAGS[ngen-bmi-forcing]:-}" ]]; then
                    read -p "Enter ngen-bmi-forcing tag: " TAGS[ngen-bmi-forcing] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            ngen-coastal)
                if [[ -z "${TAGS[ngen-coastal]:-}" ]]; then
                    read -p "Enter ngen-coastal tag: " TAGS[ngen-coastal] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            ngen-sfincs-forcing)
                if [[ -z "${TAGS[ngen-sfincs-forcing]:-}" ]]; then
                    read -p "Enter ngen-sfincs-forcing tag: " TAGS[ngen-sfincs-forcing] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            ngen)
                if [[ -z "${TAGS[ngen]:-}" ]]; then
                    read -p "Enter ngen tag: " TAGS[ngen] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            nwm-cal-mgr)
                if [[ -z "${TAGS[nwm-cal-mgr]:-}" ]]; then
                    read -p "Enter nwm-cal-mgr tag: " TAGS[nwm-cal-mgr] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            nwm-fcst-mgr)
                if [[ -z "${TAGS[nwm-fcst-mgr]:-}" ]]; then
                    read -p "Enter nwm-fcst-mgr tag: " TAGS[nwm-fcst-mgr] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
            nwm-verf)
                if [[ -z "${TAGS[nwm-verf]:-}" ]]; then
                    read -p "Enter nwm-verf tag: " TAGS[nwm-verf] || { echo "Error reading input, exiting."; exit 1; }
                fi
            ;;
        esac
    done

    # validate that all required tags have been provided
    for repo in "${SELECTED_REPOS[@]}"; do
        if [[ -z "${TAGS[$repo]:-}" ]]; then
            echo "Error: Tag for '$repo' cannot be empty"; exit 1
        fi
    done

    # special validation for nwm-verf which requires nwm-eval-mgr tag
    if [[ " ${SELECTED_REPOS[@]} " =~ " nwm-verf " ]] && [[ -z "${TAGS[nwm-eval-mgr]:-}" ]]; then
        echo "Error: nwm-eval-mgr tag is required when building nwm-verf"; exit 1
    fi
fi

# For feature builds in interactive mode, prompt for refs of any repos that don't have them set yet
# (this handles auto-added downstream dependencies)
if [[ "$BUILD_TYPE" == "feature" && -t 0 ]]; then
    for repo in "${SELECTED_REPOS[@]}"; do
        if [[ -z "${REPO_BRANCHES[$repo]:-}" ]]; then
            read -p "Enter ${repo} ref (branch or commit hash): " ans || { echo "Error reading input, exiting."; exit 1; }
            # require a ref (no default) for feature builds
            while [[ -z "$ans" ]]; do
                echo "Error: Ref cannot be empty for feature builds"
                read -p "Enter ${repo} ref (branch or commit hash): " ans || { echo "Error reading input, exiting."; exit 1; }
            done
            REPO_BRANCHES["$repo"]="$ans"
        fi
    done
fi

# prompt for dependency tags/refs (after auto-include and reorder so all repos are properly ordered)
prompt_dependency_tags "$BUILD_TYPE"

# validate dependencies
validate_dependencies

# sync forcing image repo branches to the shared ngen-forcing directory name
# this ensures update_repo_branch/checkout_repo_tag can find the branch
# when called with the directory name "ngen-forcing"
if [[ -z "${REPO_BRANCHES[ngen-forcing]:-}" ]]; then
    for fr in "${FORCING_IMAGE_REPOS[@]}"; do
        if [[ -n "${REPO_BRANCHES[$fr]:-}" ]]; then
            REPO_BRANCHES["ngen-forcing"]="${REPO_BRANCHES[$fr]}"
            break
        fi
    done
fi
# sync forcing image repo tags similarly
if [[ -z "${TAGS[ngen-forcing]:-}" ]]; then
    for fr in "${FORCING_IMAGE_REPOS[@]}"; do
        if [[ -n "${TAGS[$fr]:-}" ]]; then
            TAGS["ngen-forcing"]="${TAGS[$fr]}"
            break
        fi
    done
fi


# build SIF and update symlink
# only rebuild when docker image digest/id changes; always delete temp tar
# keeps a tiny .meta file to remember the last image key and built sif filename
get_image_key() {
    local ref="$1"
    local dig
    dig="$(docker inspect --format='{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)"
    if [[ -n "$dig" && "$dig" != "<no value>" ]]; then
        echo "${dig##*@}"   # sha256:...
        return 0
    fi
    docker inspect --format='{{.Id}}' "$ref" 2>/dev/null || true
}

ensure_image_present() {
    local repo="$1"
    local image_ref="$2"
    local mode="${3:-pull}"

    # Only relevant for pull mode; build mode already guarantees local presence
    if [[ "$mode" != "pull" ]]; then
        return 0
    fi

    echo "[$(date '+%H:%M:%S')] Pulling docker image: $image_ref"
    if ! docker pull "$image_ref"; then
        echo ""
        echo "=========================================="
        echo "DOCKER PULL FAILED"
        echo "=========================================="
        echo "Repository: ${repo}"
        echo "Image: ${image_ref}"
        echo ""
        echo "The image does not exist in the registry."
        echo "This typically happens when:"
        echo "  1. The tag hasn't been published to the registry yet"
        echo "  2. The tag name is incorrect"
        echo ""
        echo "To fix this:"
        echo "  - Select 'build' mode for ${repo} instead of 'pull'"
        echo "  - Or use a different tag that exists in the registry"
        echo "=========================================="
        exit 1
    fi

    if [[ -n "$repo" ]]; then
        IMAGE_FETCHED["$repo"]="true"
    fi
}

build_singularity_container_update_symlink() {
    local build_type="$1"
    local sif_base="$2"
    local image_ref="$3"
    local tag="$4"

    local sif_dir="${SINGULARITY_DIR}"
    local symlink_name="${sif_base}.sif"
    local ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local sif_file
    local meta_file="${sif_dir}/${sif_base}.meta"

    # naming: dev -> latest; feature -> branch name; release -> explicit tag
    if [[ "$build_type" == "development" ]]; then
        sif_file="${sif_base}-latest-${ts}.sif"
    elif [[ "$build_type" == "feature" ]]; then
        # use branch name for feature builds (sanitize by replacing / with -)
        local sanitized_tag="${tag//\//-}"
        sif_file="${sif_base}-${sanitized_tag}-${ts}.sif"
    else
        sif_file="${sif_base}-${tag}-${ts}.sif"
    fi

    # compute current image key and read previous if available
    local current_key prev_key="" prev_sif=""
    current_key="$(get_image_key "$image_ref")"
    if [[ -z "$current_key" ]]; then
        echo "could not inspect '$image_ref' to compute image key"; exit 1
    fi
    if [[ -f "$meta_file" ]]; then
        # validate meta file contains only expected variable assignments
        if grep -Eq '^[A-Z_]+=' "$meta_file" && ! grep -Eq '[;&|$(){}<>`]' "$meta_file"; then
            # Extract only the specific variables we need instead of sourcing the entire file
            # This prevents polluting the global environment with BUILD_TYPE from previous builds
            prev_key="$(grep -E '^IMAGE_KEY=' "$meta_file" | cut -d'=' -f2- || true)"
            prev_sif="$(grep -E '^SIF_FILE=' "$meta_file" | cut -d'=' -f2- || true)"
        else
            echo "Warning: meta file '$meta_file' appears corrupted or unsafe, ignoring it."
        fi
    fi

    # skip rebuild if image unchanged and previous sif exists; just refresh symlink
    if [[ -n "$prev_key" && "$prev_key" == "$current_key" && -n "$prev_sif" && -f "${sif_dir}/${prev_sif}" ]]; then
        ln -sfn "$prev_sif" "${sif_dir}/${symlink_name}"
        echo "no image change for ${image_ref} (${current_key}); kept existing SIF: ${symlink_name} -> ${prev_sif}"
        return 0
    fi

    (
        cd "$sif_dir"
        # create temp tar name and ensure cleanup on any exit
        local tar_name
        tar_name="$(mktemp -p "$sif_dir" "${sif_base}.XXXXXXXX.tar")"
        cleanup() { rm -f "$tar_name"; }
        trap cleanup EXIT INT TERM

        echo "[$(date '+%H:%M:%S')] Saving docker image to tar: ${image_ref}"
        docker save "${image_ref}" -o "${tar_name}"

        echo "[$(date '+%H:%M:%S')] Building SIF: ${sif_file} from docker-archive:${tar_name}"
        singularity build "${sif_file}" "docker-archive:${tar_name}"

        echo "[$(date '+%H:%M:%S')] Creating relative symlink: ${symlink_name} -> ${sif_file}"
        ln -sfn "${sif_file}" "${symlink_name}"

        # write/update meta so future runs can skip when unchanged
        {
            echo "IMAGE_REF=${image_ref}"
            echo "IMAGE_KEY=${current_key}"
            echo "TIMESTAMP=${ts}"
            echo "SIF_FILE=${sif_file}"
            echo "BUILD_TYPE=${build_type}"
            echo "TAG=${tag}"
        } > "${meta_file}"
    )
}

# update repo to latest from specified branch or checkout specific commit hash
update_repo_branch() {
    local repo="$1"
    local default_branch="$2"

    local ref_to_use
    ref_to_use="$(get_repo_branch "$repo" "$default_branch")"

    if [[ ! -d "$BASE_PATH/$repo" ]]; then
        echo "Error: Repository directory '$BASE_PATH/$repo' does not exist"; exit 1
    fi
    cd "$BASE_PATH/$repo"

    # check if ref is a commit hash or branch name
    if is_commit_hash "$ref_to_use"; then
        echo "[$(date '+%H:%M:%S')] Checking out $repo at commit $ref_to_use..."

        echo "[$(date '+%H:%M:%S')] Fetching from origin"
        git fetch origin

        local stash_result
        stash_result="$(git stash push --include-untracked 2>&1)"

        if ! git checkout "$ref_to_use"; then
            echo "Error: Commit '$ref_to_use' does not exist in $repo"; exit 1
        fi

        if [[ "$stash_result" != "No local changes to save" ]]; then
            if ! git stash pop; then
                echo "Warning: git stash pop failed, likely due to conflicts. Stashed changes remain in stash."
            fi
        fi
    else
        echo "[$(date '+%H:%M:%S')] Updating $repo to latest from $ref_to_use branch..."

        echo "[$(date '+%H:%M:%S')] Fetching from origin"
        git fetch origin

        local stash_result
        stash_result="$(git stash push 2>&1)"

        if ! git checkout "$ref_to_use"; then
            echo "Error: Branch '$ref_to_use' does not exist in $repo"; exit 1
        fi

        echo "[$(date '+%H:%M:%S')] Pulling latest changes from $ref_to_use"
        git pull origin "$ref_to_use" --rebase

        if [[ "$stash_result" != "No local changes to save" ]]; then
            if ! git stash pop; then
                echo "Warning: git stash pop failed, likely due to conflicts. Stashed changes remain in stash."
            fi
        fi
    fi

    if [[ "$repo" == "ngen" ]]; then
        echo "[$(date '+%H:%M:%S')] Updating submodules"
        git submodule update --init --recursive
    fi
}

# checkout repo at specified tag
checkout_repo_tag() {
    local repo="$1"
    local tag="$2"

    if [[ ! -d "$BASE_PATH/$repo" ]]; then
        echo "Error: Repository directory '$BASE_PATH/$repo' does not exist"; exit 1
    fi
    cd "$BASE_PATH/$repo"

    echo "[$(date '+%H:%M:%S')] Checking out $repo at tag $tag..."

    echo "[$(date '+%H:%M:%S')] Fetching from origin"
    git fetch origin

    local stash_result
    stash_result="$(git stash push 2>&1)"

    if ! git checkout "$tag"; then
        echo "Error: Tag '$tag' does not exist in $repo"; exit 1
    fi

    if [[ "$stash_result" != "No local changes to save" ]]; then
        if ! git stash pop; then
            echo "Warning: git stash pop failed, likely due to conflicts. Stashed changes remain in stash."
        fi
    fi

    if [[ "$repo" == "ngen" ]]; then
        echo "[$(date '+%H:%M:%S')] Updating submodules"
        git submodule update --init --recursive
    fi
}

# --- RELEASE WORKFLOW ---
if [[ "$BUILD_TYPE" == "release" ]]; then
    cd "$BASE_PATH"

    # track whether we've already checked out the ngen-forcing git directory
    declare -A RELEASE_DIR_CHECKED_OUT

    # handle ngen-bmi-forcing first if selected (dependency of ngen)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-bmi-forcing " ]]; then
        if [[ -z "${TAGS[ngen-bmi-forcing]:-}" ]]; then
            echo "Error: ngen-bmi-forcing is selected but no tag was provided."; exit 1
        fi

        if [[ "${IMAGE_SOURCE[ngen-bmi-forcing]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                if [[ "${RELEASE_DIR_CHECKED_OUT[ngen-forcing]:-}" != "true" ]]; then
                    checkout_repo_tag "ngen-forcing" "${TAGS[ngen-bmi-forcing]}"
                    RELEASE_DIR_CHECKED_OUT["ngen-forcing"]="true"
                fi
                echo "[$(date '+%H:%M:%S')] Building ngen-bmi-forcing Docker image"
                if ! docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                    --tag="${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-bmi-forcing]}" \
                    "${BASE_PATH}/ngen-forcing"; then
                    echo ""
                    echo "=========================================="
                    echo "DOCKER BUILD FAILED: ngen-bmi-forcing"
                    echo "=========================================="
                    echo "Image: ${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-bmi-forcing]}"
                    echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings"
                    echo "The build has stopped. Review the error above."
                    echo "Log file: ${LOGFILE}"
                    echo "=========================================="
                    exit 1
                fi
            else
                echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen-bmi-forcing; pulling from registry"
            ensure_image_present "ngen-bmi-forcing" "${REGISTRY}/ngen-bmi-forcing:${TAGS[ngen-bmi-forcing]}" "pull"
        fi
    fi

    # handle ngen-coastal if selected (no downstream deps)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-coastal " ]]; then
        if [[ -z "${TAGS[ngen-coastal]:-}" ]]; then
            echo "Error: ngen-coastal is selected but no tag was provided."; exit 1
        fi

        if [[ "${IMAGE_SOURCE[ngen-coastal]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                if [[ "${RELEASE_DIR_CHECKED_OUT[ngen-forcing]:-}" != "true" ]]; then
                    checkout_repo_tag "ngen-forcing" "${TAGS[ngen-coastal]}"
                    RELEASE_DIR_CHECKED_OUT["ngen-forcing"]="true"
                fi
                echo "[$(date '+%H:%M:%S')] Building ngen-coastal Docker image"
                if ! docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal" \
                    --tag="${REGISTRY}/ngen-coastal:${TAGS[ngen-coastal]}" \
                    "${BASE_PATH}/ngen-forcing"; then
                    echo ""
                    echo "=========================================="
                    echo "DOCKER BUILD FAILED: ngen-coastal"
                    echo "=========================================="
                    echo "Image: ${REGISTRY}/ngen-coastal:${TAGS[ngen-coastal]}"
                    echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal"
                    echo "The build has stopped. Review the error above."
                    echo "Log file: ${LOGFILE}"
                    echo "=========================================="
                    exit 1
                fi
            else
                echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen-coastal; pulling from registry"
            ensure_image_present "ngen-coastal" "${REGISTRY}/ngen-coastal:${TAGS[ngen-coastal]}" "pull"
        fi
    fi

    # handle ngen-sfincs-forcing if selected (no downstream deps)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-sfincs-forcing " ]]; then
        if [[ -z "${TAGS[ngen-sfincs-forcing]:-}" ]]; then
            echo "Error: ngen-sfincs-forcing is selected but no tag was provided."; exit 1
        fi

        if [[ "${IMAGE_SOURCE[ngen-sfincs-forcing]}" == "build" ]]; then
            if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                if [[ "${RELEASE_DIR_CHECKED_OUT[ngen-forcing]:-}" != "true" ]]; then
                    checkout_repo_tag "ngen-forcing" "${TAGS[ngen-sfincs-forcing]}"
                    RELEASE_DIR_CHECKED_OUT["ngen-forcing"]="true"
                fi
                echo "[$(date '+%H:%M:%S')] Building ngen-sfincs-forcing Docker image"
                if ! docker build --progress=plain --no-cache \
                    --file "${BASE_PATH}/ngen-forcing/Dockerfile.sfincs" \
                    --tag="${REGISTRY}/ngen-sfincs-forcing:${TAGS[ngen-sfincs-forcing]}" \
                    "${BASE_PATH}/ngen-forcing"; then
                    echo ""
                    echo "=========================================="
                    echo "DOCKER BUILD FAILED: ngen-sfincs-forcing"
                    echo "=========================================="
                    echo "Image: ${REGISTRY}/ngen-sfincs-forcing:${TAGS[ngen-sfincs-forcing]}"
                    echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.sfincs"
                    echo "The build has stopped. Review the error above."
                    echo "Log file: ${LOGFILE}"
                    echo "=========================================="
                    exit 1
                fi
            else
                echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen-sfincs-forcing; pulling from registry"
            ensure_image_present "ngen-sfincs-forcing" "${REGISTRY}/ngen-sfincs-forcing:${TAGS[ngen-sfincs-forcing]}" "pull"
        fi
    fi

    # ngen (build/pull even if not explicitly selected, if needed by other repos)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]] || [[ -n "${TAGS[ngen]:-}" ]]; then
        if [[ -z "${TAGS[ngen]:-}" ]]; then
            echo "Error: ngen is selected but no tag was provided."; exit 1
        fi
        if [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
            checkout_repo_tag "ngen" "${TAGS[ngen]}"

            # validate ngen-bmi-forcing tag is set (required dependency)
            if [[ -z "${TAGS[ngen-bmi-forcing]:-}" ]]; then
                echo "Error: ngen-bmi-forcing tag not set (required by ngen)"; exit 1
            fi
            forcing_tag="${TAGS[ngen-bmi-forcing]}"

            # Additional validation to ensure forcing_tag is not empty and has expected value
            if [[ -z "$forcing_tag" ]]; then
                echo "Error: forcing_tag is empty after assignment from TAGS[ngen-bmi-forcing]"; exit 1
            fi
            if [[ "$forcing_tag" != "${TAGS[ngen-bmi-forcing]}" ]]; then
                echo "Error: forcing_tag mismatch! Expected '${TAGS[ngen-bmi-forcing]}' but got '${forcing_tag}'"; exit 1
            fi

            echo "[$(date '+%H:%M:%S')] Building ngen Docker image with NGEN_FORCING_IMAGE_TAG=${forcing_tag}"
            if ! docker build --progress=plain --no-cache \
                --build-arg NGEN_FORCING_IMAGE_TAG="${forcing_tag}" \
                --tag="${REGISTRY}/ngen:${TAGS[ngen]}" \
                "${BASE_PATH}/ngen"; then
                echo ""
                echo "=========================================="
                echo "DOCKER BUILD FAILED: ngen"
                echo "=========================================="
                echo "Image: ${REGISTRY}/ngen:${TAGS[ngen]}"
                echo "Build arg NGEN_FORCING_IMAGE_TAG was set to: ${forcing_tag}"
                echo "Expected: ${TAGS[ngen-bmi-forcing]}"
                echo "Dockerfile: ${BASE_PATH}/ngen/Dockerfile"
                echo "The build has stopped. Review the error above."
                echo "Log file: ${LOGFILE}"
                echo "=========================================="
                exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen; pulling from registry"
            ensure_image_present "ngen" "${REGISTRY}/ngen:${TAGS[ngen]}" "pull"
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "pull" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pull mode requested for nwm-cal-mgr; pulling from registry"
                    ensure_image_present "nwm-cal-mgr" "${REGISTRY}/nwm-cal-mgr:${TAGS[nwm-cal-mgr]}" "pull"
                else
                    checkout_repo_tag "nwm-cal-mgr" "${TAGS[nwm-cal-mgr]}"

                    # validate ngen tag is set (required dependency)
                    if [[ -z "${TAGS[ngen]:-}" ]]; then
                        echo "Error: ngen tag not set (required by nwm-cal-mgr)"; exit 1
                    fi

                    echo "[$(date '+%H:%M:%S')] Building nwm-cal-mgr Docker image with NGEN_IMAGE_TAG=${TAGS[ngen]}"
                    docker build --progress=plain --no-cache \
                        --build-arg NGEN_IMAGE_TAG="${TAGS[ngen]}" \
                        --tag="${REGISTRY}/nwm-cal-mgr:${TAGS[nwm-cal-mgr]}" \
                        "${BASE_PATH}/nwm-cal-mgr"
                fi
            ;;
            "ngen-bmi-forcing")
                : # handled above before ngen
            ;;
            "ngen-coastal")
                : # handled above before ngen
            ;;
            "ngen-sfincs-forcing")
                : # handled above before ngen
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "pull" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pull mode requested for nwm-fcst-mgr; pulling from registry"
                    ensure_image_present "nwm-fcst-mgr" "${REGISTRY}/nwm-fcst-mgr:${TAGS[nwm-fcst-mgr]}" "pull"
                else
                    checkout_repo_tag "nwm-fcst-mgr" "${TAGS[nwm-fcst-mgr]}"

                    # validate ngen tag is set (required dependency)
                    if [[ -z "${TAGS[ngen]:-}" ]]; then
                        echo "Error: ngen tag not set (required by nwm-fcst-mgr)"; exit 1
                    fi

                    echo "[$(date '+%H:%M:%S')] Building nwm-fcst-mgr Docker image with NGEN_IMAGE_TAG=${TAGS[ngen]}"
                    docker build --progress=plain --no-cache \
                        --build-arg NGEN_IMAGE_TAG="${TAGS[ngen]}" \
                        --tag="${REGISTRY}/nwm-fcst-mgr:${TAGS[nwm-fcst-mgr]}" \
                        "${BASE_PATH}/nwm-fcst-mgr"
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "pull" ]]; then
                    echo "[$(date '+%H:%M:%S')] Pull mode requested for nwm-verf; pulling from registry"
                    ensure_image_present "nwm-verf" "${REGISTRY}/nwm-verf:${TAGS[nwm-verf]}" "pull"
                else
                    checkout_repo_tag "nwm-verf" "${TAGS[nwm-verf]}"
                    echo "[$(date '+%H:%M:%S')] Building nwm-verf Docker image"
                    docker build --progress=plain --no-cache \
                        --build-arg NWM_EVAL_MGR_TAG="${TAGS[nwm-eval-mgr]}" \
                        --tag="${REGISTRY}/nwm-verf:${TAGS[nwm-verf]}" \
                        "${BASE_PATH}/nwm-verf"
                fi
            ;;
            "ngen") : ;; # handled above
            ngencerf*)
                checkout_repo_tag "$repo" "${TAGS[$repo]}"
            ;;
        esac

        # build SIFs (explicit docker->sif pairs)
        if repo_has_sif "$repo"; then
            tag_val="${TAGS[$repo]}"
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "${REGISTRY}/${docker_img}:${tag_val}" "$tag_val"
            done
        fi
    done

    echo "Release build completed successfully!"
    exit 0
fi

# ---- DEVELOPMENT WORKFLOW ----
if [[ "$BUILD_TYPE" == "development" ]]; then
    cd "$BASE_PATH"

    for repo in "${SELECTED_REPOS[@]}"; do
        echo

        # update ngencerf* repo's development branch
        if [[ "$repo" == ngencerf* ]]; then
            update_repo_branch "$repo" "development"
        fi

        # per-repo local build paths
        case "$repo" in
            "nwm-cal-mgr")
                if [[ "${IMAGE_SOURCE[nwm-cal-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-cal-mgr" ]]; then
                        update_repo_branch "nwm-cal-mgr" "development"
                        echo "[$(date '+%H:%M:%S')] Building nwm-cal-mgr (development) Docker image with NGEN_IMAGE_TAG=latest"
                        docker build --progress=plain \
                            --build-arg NGEN_IMAGE_TAG="latest" \
                            --tag="${REGISTRY}/nwm-cal-mgr:latest" \
                            "${BASE_PATH}/nwm-cal-mgr"
                        IMAGE_FETCHED["nwm-cal-mgr"]="true"
                    else
                        echo "Error: ${BASE_PATH}/nwm-cal-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-fcst-mgr")
                if [[ "${IMAGE_SOURCE[nwm-fcst-mgr]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-fcst-mgr" ]]; then
                        update_repo_branch "nwm-fcst-mgr" "development"
                        echo "[$(date '+%H:%M:%S')] Building nwm-fcst-mgr (development) Docker image with NGEN_IMAGE_TAG=latest"
                        docker build --progress=plain \
                            --build-arg NGEN_IMAGE_TAG="latest" \
                            --tag="${REGISTRY}/nwm-fcst-mgr:latest" \
                            "${BASE_PATH}/nwm-fcst-mgr"
                        IMAGE_FETCHED["nwm-fcst-mgr"]="true"
                    else
                        echo "Error: ${BASE_PATH}/nwm-fcst-mgr not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "nwm-verf")
                if [[ "${IMAGE_SOURCE[nwm-verf]}" == "build" ]]; then
                    if [[ -d "${BASE_PATH}/nwm-verf" ]]; then
                        update_repo_branch "nwm-verf" "development"
                        echo "[$(date '+%H:%M:%S')] Building nwm-verf (development) Docker image"
                        docker build --progress=plain \
                            --build-arg NWM_EVAL_MGR_TAG="development" \
                            --tag="${REGISTRY}/nwm-verf:latest" \
                            "${BASE_PATH}/nwm-verf"
                    else
                        echo "Error: ${BASE_PATH}/nwm-verf not found; cannot build."; exit 1
                    fi
                fi
            ;;
            "ngen-bmi-forcing")
                if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                    if [[ "${IMAGE_SOURCE[ngen-bmi-forcing]}" == "build" ]]; then
                        update_repo_branch "ngen-forcing" "development"
                        echo "[$(date '+%H:%M:%S')] Building ngen-bmi-forcing (development) Docker image"
                        if ! docker build --progress=plain \
                            --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                            --tag="${REGISTRY}/ngen-bmi-forcing:latest" \
                            "${BASE_PATH}/ngen-forcing"; then
                            echo ""
                            echo "=========================================="
                            echo "DOCKER BUILD FAILED: ngen-bmi-forcing"
                            echo "=========================================="
                            echo "Image: ${REGISTRY}/ngen-bmi-forcing:latest"
                            echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings"
                            echo "The build has stopped. Review the error above."
                            echo "Log file: ${LOGFILE}"
                            echo "=========================================="
                            exit 1
                        fi
                    else
                        echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen-bmi-forcing; pulling from registry"
                        ensure_image_present "ngen-bmi-forcing" "${REGISTRY}/ngen-bmi-forcing:latest" "pull"
                    fi
                    IMAGE_FETCHED["ngen-bmi-forcing"]="true"
                else
                    echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
                fi
            ;;
            "ngen-sfincs-forcing")
                if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                    if [[ "${IMAGE_SOURCE[ngen-sfincs-forcing]}" == "build" ]]; then
                        update_repo_branch "ngen-forcing" "development"
                        echo "[$(date '+%H:%M:%S')] Building ngen-sfincs-forcing (development) Docker image"
                        if ! docker build --progress=plain \
                            --file "${BASE_PATH}/ngen-forcing/Dockerfile.sfincs" \
                            --tag="${REGISTRY}/ngen-sfincs-forcing:latest" \
                            "${BASE_PATH}/ngen-forcing"; then
                            echo ""
                            echo "=========================================="
                            echo "DOCKER BUILD FAILED: ngen-sfincs-forcing"
                            echo "=========================================="
                            echo "Image: ${REGISTRY}/ngen-sfincs-forcing:latest"
                            echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.sfincs"
                            echo "The build has stopped. Review the error above."
                            echo "Log file: ${LOGFILE}"
                            echo "=========================================="
                            exit 1
                        fi
                    else
                        echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen-sfincs-forcing; pulling from registry"
                        ensure_image_present "ngen-sfincs-forcing" "${REGISTRY}/ngen-sfincs-forcing:latest" "pull"
                    fi
                    IMAGE_FETCHED["ngen-sfincs-forcing"]="true"
                else
                    echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
                fi
            ;;
            "ngen-coastal")
                if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
                    if [[ "${IMAGE_SOURCE[ngen-coastal]}" == "build" ]]; then
                        update_repo_branch "ngen-forcing" "development"
                        echo "[$(date '+%H:%M:%S')] Building ngen-coastal (development) Docker image"
                        if ! docker build --progress=plain \
                            --file "${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal" \
                            --tag="${REGISTRY}/ngen-coastal:latest" \
                            "${BASE_PATH}/ngen-forcing"; then
                            echo ""
                            echo "=========================================="
                            echo "DOCKER BUILD FAILED: ngen-coastal"
                            echo "=========================================="
                            echo "Image: ${REGISTRY}/ngen-coastal:latest"
                            echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal"
                            echo "The build has stopped. Review the error above."
                            echo "Log file: ${LOGFILE}"
                            echo "=========================================="
                            exit 1
                        fi
                    else
                        echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen-coastal; pulling from registry"
                        ensure_image_present "ngen-coastal" "${REGISTRY}/ngen-coastal:latest" "pull"
                    fi
                    IMAGE_FETCHED["ngen-coastal"]="true"
                else
                    echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
                fi
            ;;
            "ngen")
                if [[ -d "${BASE_PATH}/ngen" ]]; then
                    if [[ "${IMAGE_SOURCE[ngen]}" == "build" ]]; then
                        update_repo_branch "ngen" "development"
                        echo "[$(date '+%H:%M:%S')] Building ngen (development) Docker image with NGEN_FORCING_IMAGE_TAG=latest"
                        docker build --progress=plain \
                            --build-arg NGEN_FORCING_IMAGE_TAG="latest" \
                            --tag="${REGISTRY}/ngen:latest" \
                            "${BASE_PATH}/ngen"
                    else
                        echo "[$(date '+%H:%M:%S')] Pull mode requested for ngen; pulling from registry"
                        ensure_image_present "ngen" "${REGISTRY}/ngen:latest" "pull"
                    fi
                    IMAGE_FETCHED["ngen"]="true"
                else
                    echo "Error: ${BASE_PATH}/ngen not found; cannot build ngen."; exit 1
                fi
            ;;
        esac

        # for each repo that produces a SIF, use the locally built image if mode==build,
        # otherwise pull the image
        if repo_has_sif "$repo"; then
            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"
                IMAGE="${REGISTRY}/${docker_img}:latest"

                if [[ "${IMAGE_SOURCE[$repo]}" != "build" ]]; then
                    if [[ "${IMAGE_FETCHED[$repo]:-}" == "true" ]]; then
                        echo "[$(date '+%H:%M:%S')] Using available image for SIF: $IMAGE"
                    else
                        ensure_image_present "$repo" "$IMAGE" "pull"
                    fi
                else
                    echo "[$(date '+%H:%M:%S')] Using locally built image for SIF: $IMAGE"
                fi

                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "$IMAGE" "latest"
            done
        fi
    done

    echo "Development build completed successfully!"
    exit 0
fi

# ---- FEATURE WORKFLOW ----
if [[ "$BUILD_TYPE" == "feature" ]]; then
    cd "$BASE_PATH"

    # track whether we've already updated the ngen-forcing git directory
    declare -A FEATURE_DIR_UPDATED

    # handle ngen-bmi-forcing first (dependency of ngen) if it's in SELECTED_REPOS
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-bmi-forcing " ]]; then
        if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
            if [[ "${FEATURE_DIR_UPDATED[ngen-forcing]:-}" != "true" ]]; then
                update_repo_branch "ngen-forcing" "feature"
                FEATURE_DIR_UPDATED["ngen-forcing"]="true"
            fi

            # get Docker tag based on branch name
            forcing_docker_tag="$(get_docker_tag_for_repo "ngen-bmi-forcing" "$BUILD_TYPE")"

            echo "[$(date '+%H:%M:%S')] Building ngen-bmi-forcing (${forcing_docker_tag}) Docker image"
            if ! docker build --progress=plain \
                --file "${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings" \
                --tag="${REGISTRY}/ngen-bmi-forcing:${forcing_docker_tag}" \
                "${BASE_PATH}/ngen-forcing"; then
                echo ""
                echo "=========================================="
                echo "DOCKER BUILD FAILED: ngen-bmi-forcing"
                echo "=========================================="
                echo "Image: ${REGISTRY}/ngen-bmi-forcing:${forcing_docker_tag}"
                echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.bmi-forcings"
                echo "The build has stopped. Review the error above."
                echo "Log file: ${LOGFILE}"
                echo "=========================================="
                exit 1
            fi
        else
            echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
        fi
    fi

    # handle ngen-coastal if it's in SELECTED_REPOS (no downstream deps)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-coastal " ]]; then
        if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
            if [[ "${FEATURE_DIR_UPDATED[ngen-forcing]:-}" != "true" ]]; then
                update_repo_branch "ngen-forcing" "feature"
                FEATURE_DIR_UPDATED["ngen-forcing"]="true"
            fi

            # get Docker tag based on branch name
            coastal_docker_tag="$(get_docker_tag_for_repo "ngen-coastal" "$BUILD_TYPE")"

            echo "[$(date '+%H:%M:%S')] Building ngen-coastal (${coastal_docker_tag}) Docker image"
            if ! docker build --progress=plain \
                --file "${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal" \
                --tag="${REGISTRY}/ngen-coastal:${coastal_docker_tag}" \
                "${BASE_PATH}/ngen-forcing"; then
                echo ""
                echo "=========================================="
                echo "DOCKER BUILD FAILED: ngen-coastal"
                echo "=========================================="
                echo "Image: ${REGISTRY}/ngen-coastal:${coastal_docker_tag}"
                echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.ngencoastal"
                echo "The build has stopped. Review the error above."
                echo "Log file: ${LOGFILE}"
                echo "=========================================="
                exit 1
            fi
        else
            echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
        fi
    fi

    # handle ngen-sfincs-forcing if it's in SELECTED_REPOS (no downstream deps)
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen-sfincs-forcing " ]]; then
        if [[ -d "${BASE_PATH}/ngen-forcing" ]]; then
            if [[ "${FEATURE_DIR_UPDATED[ngen-forcing]:-}" != "true" ]]; then
                update_repo_branch "ngen-forcing" "feature"
                FEATURE_DIR_UPDATED["ngen-forcing"]="true"
            fi

            # get Docker tag based on branch name
            sfincs_docker_tag="$(get_docker_tag_for_repo "ngen-sfincs-forcing" "$BUILD_TYPE")"

            echo "[$(date '+%H:%M:%S')] Building ngen-sfincs-forcing (${sfincs_docker_tag}) Docker image"
            if ! docker build --progress=plain \
                --file "${BASE_PATH}/ngen-forcing/Dockerfile.sfincs" \
                --tag="${REGISTRY}/ngen-sfincs-forcing:${sfincs_docker_tag}" \
                "${BASE_PATH}/ngen-forcing"; then
                echo ""
                echo "=========================================="
                echo "DOCKER BUILD FAILED: ngen-sfincs-forcing"
                echo "=========================================="
                echo "Image: ${REGISTRY}/ngen-sfincs-forcing:${sfincs_docker_tag}"
                echo "Dockerfile: ${BASE_PATH}/ngen-forcing/Dockerfile.sfincs"
                echo "The build has stopped. Review the error above."
                echo "Log file: ${LOGFILE}"
                echo "=========================================="
                exit 1
            fi
        else
            echo "Error: ${BASE_PATH}/ngen-forcing not found; cannot build."; exit 1
        fi
    fi

    # build ngen first if selected, so downstream builds may use it
    if [[ " ${SELECTED_REPOS[@]} " =~ " ngen " ]]; then
        if [[ -d "${BASE_PATH}/ngen" ]]; then
            update_repo_branch "ngen" "feature"

            # get Docker tag for ngen based on its branch
            ngen_docker_tag="$(get_docker_tag_for_repo "ngen" "$BUILD_TYPE")"

            # get ngen-bmi-forcing tag to use as build arg
            # Use DEPENDENCY_TAGS if specified (existing tag), otherwise derive from ngen-bmi-forcing branch
            if [[ -n "${DEPENDENCY_TAGS[ngen]:-}" ]]; then
                ngen_forcing_docker_tag="${DEPENDENCY_TAGS[ngen]}"
                echo "[$(date '+%H:%M:%S')] Using specified ngen-bmi-forcing tag: ${ngen_forcing_docker_tag}"
            else
                ngen_forcing_docker_tag="$(get_docker_tag_for_repo "ngen-bmi-forcing" "$BUILD_TYPE")"
            fi

            echo "[$(date '+%H:%M:%S')] Building ngen (${ngen_docker_tag}) Docker image with NGEN_FORCING_IMAGE_TAG=${ngen_forcing_docker_tag}"
            docker build --progress=plain \
                --build-arg NGEN_FORCING_IMAGE_TAG="${ngen_forcing_docker_tag}" \
                --tag="${REGISTRY}/ngen:${ngen_docker_tag}" \
                "${BASE_PATH}/ngen"
        else
            echo "Error: ${BASE_PATH}/ngen not found; cannot build ngen."; exit 1
        fi
    fi

    for repo in "${SELECTED_REPOS[@]}"; do
        echo

        # update ngencerf* repo's feature branch
        if [[ "$repo" == ngencerf* ]]; then
            update_repo_branch "$repo" "feature"
        fi

        # per-repo local build paths (mirrors development but with rc tags/args)
        case "$repo" in
            "nwm-cal-mgr")
                if [[ -d "${BASE_PATH}/nwm-cal-mgr" ]]; then
                    update_repo_branch "nwm-cal-mgr" "feature"

                    # get Docker tag for nwm-cal-mgr based on its branch
                    cal_mgr_docker_tag="$(get_docker_tag_for_repo "nwm-cal-mgr" "$BUILD_TYPE")"

                    # get ngen tag to use as build arg
                    # Use DEPENDENCY_TAGS if specified (existing tag), otherwise derive from ngen branch
                    if [[ -n "${DEPENDENCY_TAGS[nwm-cal-mgr]:-}" ]]; then
                        ngen_docker_tag="${DEPENDENCY_TAGS[nwm-cal-mgr]}"
                        echo "[$(date '+%H:%M:%S')] Using specified ngen tag: ${ngen_docker_tag}"
                    else
                        ngen_docker_tag="$(get_docker_tag_for_repo "ngen" "$BUILD_TYPE")"
                    fi

                    echo "[$(date '+%H:%M:%S')] Building nwm-cal-mgr (${cal_mgr_docker_tag}) Docker image with NGEN_IMAGE_TAG=${ngen_docker_tag}"
                    docker build --progress=plain \
                        --build-arg NGEN_IMAGE_TAG="${ngen_docker_tag}" \
                        --tag="${REGISTRY}/nwm-cal-mgr:${cal_mgr_docker_tag}" \
                        "${BASE_PATH}/nwm-cal-mgr"
                else
                    echo "Error: ${BASE_PATH}/nwm-cal-mgr not found; cannot build."; exit 1
                fi
            ;;
            "nwm-fcst-mgr")
                if [[ -d "${BASE_PATH}/nwm-fcst-mgr" ]]; then
                    update_repo_branch "nwm-fcst-mgr" "feature"

                    # get Docker tag for nwm-fcst-mgr based on its branch
                    fcst_mgr_docker_tag="$(get_docker_tag_for_repo "nwm-fcst-mgr" "$BUILD_TYPE")"

                    # get ngen tag to use as build arg
                    # Use DEPENDENCY_TAGS if specified (existing tag), otherwise derive from ngen branch
                    if [[ -n "${DEPENDENCY_TAGS[nwm-fcst-mgr]:-}" ]]; then
                        ngen_docker_tag="${DEPENDENCY_TAGS[nwm-fcst-mgr]}"
                        echo "[$(date '+%H:%M:%S')] Using specified ngen tag: ${ngen_docker_tag}"
                    else
                        ngen_docker_tag="$(get_docker_tag_for_repo "ngen" "$BUILD_TYPE")"
                    fi

                    echo "[$(date '+%H:%M:%S')] Building nwm-fcst-mgr (${fcst_mgr_docker_tag}) Docker image with NGEN_IMAGE_TAG=${ngen_docker_tag}"
                    docker build --progress=plain \
                        --build-arg NGEN_IMAGE_TAG="${ngen_docker_tag}" \
                        --tag="${REGISTRY}/nwm-fcst-mgr:${fcst_mgr_docker_tag}" \
                        "${BASE_PATH}/nwm-fcst-mgr"
                else
                    echo "Error: ${BASE_PATH}/nwm-fcst-mgr not found; cannot build."; exit 1
                fi
            ;;
            "nwm-verf")
                if [[ -d "${BASE_PATH}/nwm-verf" ]]; then
                    update_repo_branch "nwm-verf" "feature"

                    # get Docker tag for nwm-verf based on its branch
                    verf_docker_tag="$(get_docker_tag_for_repo "nwm-verf" "$BUILD_TYPE")"

                    # nwm-eval-mgr branch is stored in DEPENDENCY_TAGS[nwm-verf]
                    nwm_eval_mgr_branch="${DEPENDENCY_TAGS[nwm-verf]:-}"
                    if [[ -z "$nwm_eval_mgr_branch" ]]; then
                        nwm_eval_mgr_branch="development"
                    fi

                    echo "[$(date '+%H:%M:%S')] Building nwm-verf (${verf_docker_tag}) Docker image with NWM_EVAL_MGR_TAG=${nwm_eval_mgr_branch}"
                    docker build --progress=plain \
                        --build-arg NWM_EVAL_MGR_TAG="${nwm_eval_mgr_branch}" \
                        --tag="${REGISTRY}/nwm-verf:${verf_docker_tag}" \
                        "${BASE_PATH}/nwm-verf"
                else
                    echo "Error: ${BASE_PATH}/nwm-verf not found; cannot build."; exit 1
                fi
            ;;
            "ngen-bmi-forcing")
                : # handled above before ngen
            ;;
            "ngen-coastal")
                : # handled above before ngen
            ;;
            "ngen-sfincs-forcing")
                : # handled above before ngen
            ;;
            "ngen")
                : # handled above if building
            ;;
        esac

        # for each repo that produces a SIF, use the locally built image
        if repo_has_sif "$repo"; then
            # get Docker tag for this repo based on its branch
            repo_docker_tag="$(get_docker_tag_for_repo "$repo" "$BUILD_TYPE")"

            for pair in $(images_for_repo "$repo"); do
                [[ -z "$pair" ]] && continue
                docker_img="${pair%%|*}"
                sif_name="${pair##*|}"

                IMAGE="${REGISTRY}/${docker_img}:${repo_docker_tag}"
                echo "[$(date '+%H:%M:%S')] Using locally built image for SIF: $IMAGE"

                build_singularity_container_update_symlink "$BUILD_TYPE" "$sif_name" "$IMAGE" "$repo_docker_tag"
            done
        fi
    done

    echo "feature build completed successfully!"
    exit 0
fi

# --- INVALID BUILD_TYPE ---
echo "Error: Invalid BUILD_TYPE '${BUILD_TYPE}'. Must be one of: development, release, feature"
exit 1
