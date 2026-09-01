#!/bin/bash
# Define color codes
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

declare -a TEMP_BRANCHES

# Release branch names are selected in main(). The default environment uses
# development/ngwpc-candidate/ngwpc-release. Passing PW selects the -pw variants.
DEVELOPMENT_BRANCH="development"
RELEASE_CANDIDATE_BRANCH="ngwpc-candidate"
RELEASE_BRANCH="ngwpc-release"
BRANCH_ENVIRONMENT="STANDARD"

# Toggle for printing the exact 'gh' commands being executed.
# Printed commands go to STDERR so that JSON captures using $(...) are not polluted.
DEBUG_GH=false

#-----------------------------------------
# Function: usage
# Displays usage information and exits.
#-----------------------------------------
usage() {
  cat <<EOF

Usage: $(basename "$0") --release-type <RC|OFFICIAL|OWP> [OPTIONS]

This script automates the release process for GitHub repositories repositories listed in a JSON
configuration file, handling merges, submodules, and versioning.

Release Type Workflows: 
  RC — Release Candidate Mode
      - First RC (-rc1) for a release: merges development → ngwpc-candidate (creating ngwpc-candidate 
        from development if it doesn't exist yet), updates ngwpc-candidate's submodule pointers if 
        applicable, then tags and creates a pre-release on ngwpc-candidate.
      - Subsequent RCs (-rc2, -rc3, ...): skips the merge (assumes ngwpc-candidate already has what it
        needs), updates ngwpc-candidate's submodule pointers if applicable, tags and creates the next 
        pre-release, then merges ngwpc-candidate back into development and updates development's 
        submodule pointers if applicable. A conflict updating development's submodule pointers fails 
        that step only — the RC pre-release already created is not rolled back.
      - The next RC number is determined automatically from existing git tags matching <release>-rcN[-pw].
      - In the PW environment, the tag gets a -pw suffix (e.g. 10.2-rcN-pw).

  OFFICIAL — Official Release Mode
    - Merges ngwpc-candidate → ngwpc-release (creating ngwpc-release if needed), updates submodule 
      pointers if applicable, generates a changelog (commit log since the last official tag, written
      to changelogs/<repo>_<release>_changelog.txt), tags and creates the official release on 
      ngwpc-release, then merges ngwpc-release back into development. A conflict updating development's 
      submodule pointers fails that step only — the Official release already created is not rolled back.
    - In the PW environment, the tag gets a -pw suffix (e.g. 10.2-pw).

  OWP — Branch-Only Mode
    - Creates ngwpc-<release> (or ngwpc-<release>-pw under PW) branch directly from ngwpc-release and 
      pushes it. No merge request, no tagging, no GitHub release — the repo is done as soon as the 
      branch is pushed.
    - This branch is what gets submitted as a pull request to the upstream NOAA OWP parent repository;
      the script only prepares and pushes it, it does not open that PR for you.
    - In the PW environment, the tag gets a -pw suffix (e.g. 10.2-pw).

OPTIONS
  Required option:
    -r, --release-type TYPE   Release workflow: RC, OFFICIAL, or OWP.

  Optional options:
    -c, --config FILE         Configuration JSON file.
                              Default: createReleaseConfig.json
    -v, --verbose             Print the exact 'gh' commands being executed
                              Default: false
    -w, --wait-time SECONDS   Maximum wait before prompting while a PR is blocked.
                              Default: 60
    -e, --environment ENV     Branch/release environment: STANDARD or PW.
                              Default: STANDARD
    -a, --automatic-submodules For repos with has_submodules=true, update
                              submodule pointers automatically. Without this
                              flag (the default), the script pauses instead
                              so you can update and push them by hand on
                              each relevant branch, then continue.
                              Default: false (manual)
    -h, --help                Display this help and exit.

Environment branches:
  STANDARD:
    development
    ngwpc-candidate
    ngwpc-release

  PW:
    development-pw
    ngwpc-candidate-pw
    ngwpc-release-pw

Release tags:
  STANDARD RC:       10.2-rc1
  STANDARD official: 10.2
  PW RC:             10.2-rc1-pw
  PW official:       10.2-pw

Examples:
  $(basename "$0") --release-type RC
  $(basename "$0") --release-type OFFICIAL --config release_config.json
  $(basename "$0") --release-type RC --config release_config.json --wait-time 120 --environment PW
  $(basename "$0") --release-type OWP --environment PW
  $(basename "$0") --release-type RC --automatic-submodules

Per-repo config field "env" (optional; PW, AWS, or ALL; defaults to ALL):
  Controls which -e environment(s) a repo entry is processed under, independent
  of the "skip" flag:
    -e PW                -> repo runs only if env is PW or ALL
    -e STANDARD (default) -> repo runs only if env is AWS or ALL
  A repo entry with "skip": true is always skipped regardless of "env".
EOF
  exit "${1:-0}"
}

#-----------------------------------------
# Function: git_push
# Quiet wrapper around `git push` that suppresses routine output
# (e.g., GitHub's "Create a pull request" hint) but still surfaces
# real errors. It:
#   - runs `git push -q` with all arguments passed through
#   - captures stderr/stdout on failure and prints them
#
# Arguments:
#   $@ - Arguments passed directly to `git push`
#
# Returns:
#   0 on success; 1 on failure (after printing the captured error output)
#-----------------------------------------
git_push() {
  if ! out=$(git push -q "$@" 2>&1); then
    echo -e "${RED}git push failed: git push $*${NC}"
    echo "$out" >&2
    return 1
  fi
  return 0
}

#-----------------------------------------
# Function: run_gh
# Prints and executes a `gh` command.
#
# WHY:
#   We want to see the exact `gh` command lines that run (for debugging).
#
# BEHAVIOR:
#   - If DEBUG_GH=true, prints:  Executing: gh <args...>
#   - The print goes to STDERR so that callers that capture STDOUT via $(...) do not
#     get the "Executing:" line mixed into JSON or other command output.
#   - Returns `gh`'s exit status and streams `gh`'s STDOUT/STDERR unchanged.
#
# USAGE:
#   run_gh release create ...
#   json=$(run_gh pr create --json number)
#-----------------------------------------
run_gh() {
  local args=("$@")
  if [ "$DEBUG_GH" = true ]; then
    printf 'Executing: ' >&2; printf '%q ' gh "${args[@]}" >&2; echo >&2
  fi
  gh "${args[@]}"
}

#-----------------------------------------
# Function: clean_and_encode_project
# Normalizes a GitHub remote URL to the canonical "owner/repo" form.
# Works for HTTPS and SSH remotes, and strips embedded credentials and .git suffix.
#-----------------------------------------
clean_and_encode_project() {
  local project_url="$1"
  project_url=$(echo "$project_url" | sed -e 's#^https\?://[^/]*@#https://#')
  project_url=$(echo "$project_url" | sed -e 's#^https://github\.com/##')
  project_url=$(echo "$project_url" | sed -e 's#^git@github\.com:##')
  project_url=$(echo "$project_url" | sed -e 's#\.git$##')
  echo "$project_url"
}

#-----------------------------------------
# Function: repo_env_applies
# Decides whether a repo config entry should be processed under the current
# BRANCH_ENVIRONMENT (STANDARD or PW), based on the config's optional "env"
# field (PW, AWS, or ALL; defaults to ALL when absent).
#
# Rules:
#   -e PW       -> repo processed only if env is PW or ALL
#   -e STANDARD -> repo processed only if env is AWS or ALL
#
# Arguments:
#   $1 - The repo's env value (already uppercased; "ALL" if unset)
#
# Returns:
#   0 if the repo should be processed under the current environment, 1 otherwise.
#-----------------------------------------
repo_env_applies() {
  local repo_env="$1"
  case "$BRANCH_ENVIRONMENT" in
    PW)
      [[ "$repo_env" == "PW" || "$repo_env" == "ALL" ]]
      ;;
    STANDARD)
      [[ "$repo_env" == "AWS" || "$repo_env" == "ALL" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

#-----------------------------------------
# Function: create_merge_request
# Creates a pull request using the GitHub CLI (`gh`).
#
# Arguments:
#   $1 - Source branch (head)
#   $2 - Target branch (base)
#   $3 - Title for the pull request
#
# Behavior:
#   - Uses `gh api` to POST the PR and echoes the PR number on success.
#   - If a matching open PR already exists (HTTP 422 case), queries for it and echoes its number.
#
# Requires:
#   REPO_PROJECT to be set to "owner/repo".
#
# Returns:
#   0 if a PR was created or an existing one was found; 1 otherwise.
#-----------------------------------------
create_merge_request() {
  local source_branch="$1"
  local target_branch="$2"
  local title="$3"
  local pr_num

  echo
  echo -e "Creating pull request from ${GREEN}$source_branch${NC} to ${GREEN}$target_branch${NC}" >&2

  # Try to create PR via REST API and capture its number
  if pr_num=$(run_gh api \
        -X POST "repos/$REPO_PROJECT/pulls" \
        -f title="$title" \
        -f head="$source_branch" \
        -f base="$target_branch" \
        --jq '.number'); then
    if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
      echo "$pr_num"
      return 0
    fi
  fi

  # If it already exists (typical 422 case), look up the open PR matching head/base
  local owner="${REPO_PROJECT%%/*}"
  if pr_num=$(run_gh api \
        -X GET "repos/$REPO_PROJECT/pulls?state=open&head=${owner}:${source_branch}&base=${target_branch}" \
        --jq '.[0].number' 2>/dev/null); then
    if [[ -n "$pr_num" && "$pr_num" != "null" ]]; then
      echo "$pr_num"
      return 0
    fi
  fi

  echo -e "${RED}Error creating Pull Request from $source_branch to $target_branch${NC}" >&2
  return 1
}

#-----------------------------------------
# Function: trigger_merge
# Triggers merging a pull request using the GitHub CLI (`gh`).
#
# Arguments:
#   $1 - Pull request number
#   $2 - (Optional) delete branch flag:
#        "true"  -> delete source branch after merge (default)
#        "false" -> preserve source branch
#
# Behavior:
#   - If delete flag is true, passes --delete-branch to gh.
#   - Attempts immediate merge first; if not allowed, falls back to auto-merge.
#   - Logs clearly whether the branch will be deleted or preserved.
#
# Returns:
#   0 on success, 1 on failure.
#-----------------------------------------
trigger_merge() {
  local pr_number="$1"
  local delete_branch="${2:-true}"   # default: true
  local delete_flag=()

  if [[ "$delete_branch" == "true" ]]; then
    delete_flag=(--delete-branch)
    echo "Triggering merge for PR #$pr_number (source branch WILL be deleted)..."
  else
    echo "Triggering merge for PR #$pr_number (source branch will be PRESERVED)..."
  fi


  # 1) Try to merge immediately (non-auto). Deletes source branch on success.
  local merge_output auto_output
  if merge_output=$(run_gh pr merge "$pr_number" --merge "${delete_flag[@]}" 2>&1); then
    echo "Merge triggered successfully."
    echo
    return 0
  fi

  # 2) Fall back to auto-merge (queues merge once requirements are met).
  if auto_output=$(run_gh pr merge "$pr_number" --merge --auto "${delete_flag[@]}" 2>&1); then
    echo "Auto-merge enabled (will merge when requirements are met)."
    echo
    return 0
  fi

  echo -e "${RED}Error triggering merge for PR $pr_number.${NC}"
  echo -e "${YELLOW}  Direct merge attempt said:${NC} $merge_output"
  echo -e "${YELLOW}  Auto-merge attempt said:${NC} $auto_output"
  return 1
}

#-----------------------------------------
# Function: poll_merge_status
# Polls the pull request via `gh` until its status is either "MERGED" or "CLOSED".
#
# Arguments:
#   $1 - Pull request number
#   $2 - Maximum wait time in seconds
#
# Behavior:
#   Continuously queries the pull request state and displays progress until the state
#   is either "MERGED" or "CLOSED", or until max_wait is exceeded — at which point
#   this gives up and returns failure rather than waiting indefinitely (e.g. a PR
#   queued via auto-merge whose required check never reports).
#-----------------------------------------
poll_merge_status() {
  local pr_number="$1"
  local max_wait="${2:-300}"
  local elapsed=0

  echo "Waiting up to $max_wait seconds for pull request $pr_number to complete..."
  while true; do
    local state
    # We suppress gh's own stderr here to keep logs tidy; the wrapper's
    # "Executing:" line is printed to STDERR and will also be suppressed.
    state=$(run_gh pr view "$pr_number" --json state -q '.state' 2>/dev/null || echo "")
    if [[ "$state" == "MERGED" ]]; then
      echo "Merge is complete."
      return 0
    elif [[ "$state" == "CLOSED" ]]; then
      echo -e "${RED}Pull request closed without merging.${NC}"
      return 1
    fi

    if (( elapsed >= max_wait )); then
      echo -e "${RED}Gave up waiting for pull request $pr_number to complete after ${max_wait}s (last state: ${state:-unknown}).${NC}"
      return 1
    fi

    echo "Current pull request state: ${state:-unknown}. Waiting 10 seconds..."
    sleep 10
    elapsed=$((elapsed + 10))
  done
}

#-----------------------------------------
# Function: wait_until_mergeable
#
# Waits until a PR is "merge-button eligible":
#   - NOT a draft, and
#   - NOT in conflict (mergeStateStatus != DIRTY), and
#   - NOT explicitly blocked (mergeStateStatus != BLOCKED).
#
# We DO allow: CLEAN, UNSTABLE, BEHIND, HAS_HOOKS, UNKNOWN
# Rationale: The UI shows the "Merge" button for those states when branch
#            protection doesn’t require passing checks. The merge API will
#            still 405 if rules block you, so don’t pre-block here.
#
# Arguments:
#   $1 - Pull Request number
#   $2 - Maximum wait time in seconds
#
# gh pr view output:
#   Command: gh pr view <PR#> --json isDraft,mergeStateStatus
#   Example return:
#     {
#       "isDraft": false,
#       "mergeStateStatus": "CLEAN"
#     }
#
#   Common values for mergeStateStatus:
#     CLEAN     -> mergeable right now (no conflicts, requirements met)
#     DIRTY     -> conflicts must be resolved
#     BLOCKED   -> explicitly blocked (e.g. required reviews not approved)
#     DRAFT     -> draft PR, cannot merge
#     UNSTABLE  -> checks pending/failing, but merge button may still be available
#     BEHIND    -> branch behind base, may need update (only blocks if required)
#     HAS_HOOKS -> waiting on external hooks
#     UNKNOWN   -> status not yet computed
#
# Behavior:
#   - Polls the PR and returns success once the PR is not draft/dirty/blocked.
#   - If the timeout is reached, prompts the user to Continue waiting or Skip.
#
# Returns:
#   0 if the PR becomes mergeable within the timeout,
#   1 on timeout (if user chooses Skip).
#-----------------------------------------
wait_until_mergeable() {
  local pr_number="$1"
  local max_wait="$2"
  local elapsed=0

  echo "Waiting up to $max_wait seconds for PR $pr_number to be mergeable..."

  while true; do
    # Query both draft state and merge state from GitHub
    local checks_state
    checks_state=$(run_gh pr view "$pr_number" --json isDraft,mergeStateStatus \
                     -q '[.isDraft, .mergeStateStatus]' 2>/dev/null || echo '["",""]')
    local is_draft state
    is_draft=$(echo "$checks_state" | jq -r '.[0]')
    state=$(echo "$checks_state"   | jq -r '.[1] // "UNKNOWN"')

    echo "PR $pr_number status: isDraft=$is_draft, mergeStateStatus=$state"

    # Proceed if not a draft, not in conflict, not explicitly blocked
    if [[ "$is_draft" != "true" && "$state" != "DIRTY" && "$state" != "BLOCKED" ]]; then
      echo "Pull request $pr_number appears mergeable (state: $state)"
      return 0
    fi

    if (( elapsed >= max_wait )); then
      if [ ! -t 0 ]; then
        echo -e "${RED}PR $pr_number still not mergeable after ${max_wait}s (state: ${state:-unknown}); stdin isn't a terminal, so skipping instead of prompting.${NC}"
        return 1
      fi
      while true; do
        read -n 1 -s -r -p "Pull Request $pr_number not ready (state: ${state:-unknown}). (C)ontinue waiting, (S)kip: " choice
        echo
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        case "$choice" in
          C) echo "Continuing to wait..."; elapsed=0; break;;
          S) echo "Skipping repository due to timeout."; return 1;;
          *) echo "Invalid option. Please enter C to continue waiting or S to skip.";;
        esac
      done
    fi

    echo "Waiting for PR $pr_number to be mergeable (state: ${state:-unknown})..."
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

#-----------------------------------------
# Function: create_release
# Creates a GitHub release using the GitHub CLI (`gh release create`).
#
# Arguments:
#   $1 - Release tag (e.g., "v1.1")
#   $2 - Release name (e.g., "Release 1.1")
#   $3 - Release notes (description)
#   $4 - Ref branch (the branch to base the release on)
#
# Behavior:
#   - Invokes `gh release create` and captures its stdout (the release URL).
#   - Prints the URL with a clear label: "New release: <url>".
#
# Returns:
#   0 on success, 1 on failure.
#-----------------------------------------
create_release() {
  local release_tag="$1"
  local release_name="$2"
  local release_notes="$3"
  local ref_branch="$4"

  local prerelease_flag=()
  [[ "$RELEASE_TYPE" == "RC" ]] && prerelease_flag=(--prerelease)

  # Capture stdout from gh (which is the release URL on success). Our run_gh
  # prints the "Executing:" line to STDERR, so it won't pollute this capture.
  local release_url
  if release_url=$(run_gh release create "$release_tag" \
        --title "$release_name" \
        --notes "$release_notes" \
        --target "$ref_branch" \
        "${prerelease_flag[@]}"); then
    # Print with context so the URL isn't a naked line in logs
    echo -e "Release ${GREEN}$release_url${NC} created successfully."
    return 0
  fi

  echo -e "${RED}Error creating release.${NC}"
  return 1
}

#-----------------------------------------
# Function: execute_merge_request
# Combines creating a pull request, waiting until it becomes mergeable, and triggering the merge.
# We validate it locally before creating the PR to better ensure that it will succeed.
#
# Arguments:
#   $1 - Source branch
#   $2 - Target branch
#   $3 - Title for the pull request
#   $4 - Wait time (seconds)
#   $5 - (Optional) delete source branch after merge: true or false (default: false)
#
# Behavior:
#   - Checks if the source branch has changes compared to the target.
#   - Attempts a local merge to detect conflicts before creating a pull request.
#   - Only proceeds to create the PR (via `gh`) if the merge is clean or only submodule-pointer conflicts exist.
#
# Returns:
#   0 on success; 1 on failure.
#-----------------------------------------
execute_merge_request() {
  local source_branch="$1"
  local target_branch="$2"
  local title="$3"
  local wait_time="$4"
  local delete_source_branch="${5:-false}"

  local branch_created=0  # Flag to track if the target branch was just created
  local previous_branch
  previous_branch=$(git rev-parse --abbrev-ref HEAD)  # Save current branch

  # Check if the target branch exists in the remote repository
  # echo Checking if $target_branch exists...
  if ! git ls-remote --exit-code --heads origin "$target_branch" > /dev/null 2>&1; then
    ### for debugging
    git ls-remote --exit-code --heads origin "$target_branch" || true
    ###
    echo -e "${YELLOW}Target branch $target_branch does not exist. Creating it from $source_branch...${NC}"

    # Create the target branch directly from the current remote source branch.
    if ! git fetch --quiet origin "$source_branch"; then
      echo -e "${RED}Unable to fetch source branch $source_branch.${NC}"
      return 1
    fi
    git branch --quiet -D "$target_branch" >/dev/null 2>&1 || true
    if ! git checkout --quiet -b "$target_branch" "origin/$source_branch"; then
      echo -e "${RED}Unable to create local branch $target_branch from origin/$source_branch.${NC}"
      return 1
    fi
    git_push --set-upstream origin "$target_branch" || return 1

    echo -e "${GREEN}Successfully created and pushed branch $target_branch from $source_branch.${NC}"
    branch_created=1  # Mark that we just created the branch
  fi

  # If the target branch was just created, skip the pull request
  if [ "$branch_created" -eq 1 ]; then
    echo -e "${YELLOW}Skipping pull request since $target_branch was just created from $source_branch.${NC}"
    git checkout --quiet "$previous_branch"  # Restore original branch
    return 0
  fi

  echo
  echo -e "${YELLOW}Checking merge viability between $source_branch and $target_branch...${NC}"

  # Ensure we have the latest updates for source and target branches
  if ! git fetch --quiet origin "$source_branch" "$target_branch"; then
    echo -e "${RED}Unable to fetch $source_branch and $target_branch from origin.${NC}"
    return 1
  fi

  # Definitive check: is source actually ahead of target?
  # Format: "behind ahead" (target behind source, source ahead of target)
  local behind ahead
  read behind ahead < <(git rev-list --left-right --count "origin/$target_branch...origin/$source_branch")
  if [[ "${ahead:-0}" -eq 0 ]]; then
    echo -e "${YELLOW}No changes detected in $source_branch relative to $target_branch (ahead=$ahead). Skipping pull request.${NC}"
    git checkout --quiet "$previous_branch"
    return 0
  fi

  # Create a temporary test merge branch (delete if it already exists)
  local temp_merge_branch="merge_test_${source_branch}_to_${target_branch}"
  git branch --quiet -D "$temp_merge_branch" >/dev/null 2>&1 || true
  git checkout --quiet -b "$temp_merge_branch" "origin/$target_branch"
  TEMP_BRANCHES+=("$temp_merge_branch")

  # Attempt to merge the source branch into the target branch quietly
  if ! git merge --no-commit --no-ff "origin/$source_branch" ; then
    echo -e "${YELLOW}Merge conflicts detected between $source_branch and $target_branch.. Checking if they are only submodule pointers...${NC}"

    # Get list of conflicting files
    local conflict_files non_submodule_conflicts
    conflict_files=$(git diff --name-only --diff-filter=U)
    non_submodule_conflicts=$(echo "$conflict_files" | grep -vE '^extern/[^/]+(/[^/]+)?$' || true)

    if [[ -n "$non_submodule_conflicts" ]]; then
      echo -e "${RED}Merge has conflicts outside submodules. Pull request will not be created.${NC}"
      echo
      echo -e "${YELLOW}Conflicting files:${NC}"
      echo "$conflict_files"
      git merge --abort
      git checkout --quiet "$previous_branch"
      git branch --quiet -D "$temp_merge_branch"
      return 1
    else
      echo -e "${GREEN}Only submodule pointer conflicts detected. The pull request will be allowed to resolve them according to repository rules.${NC}"
    fi
  fi

  # A --no-commit test merge leaves MERGE_HEAD in place even when it succeeds.
  # Always abort the test merge before restoring the user's original branch.
  git merge --abort >/dev/null 2>&1 || true

  echo -e "${GREEN}Local merge test completed. Proceeding with pull request creation...${NC}"
  echo
  if ! git checkout --quiet "$previous_branch"; then
    echo -e "${RED}Unable to restore branch $previous_branch after the merge test.${NC}"
    return 1
  fi
  git branch --quiet -D "$temp_merge_branch" >/dev/null 2>&1 || true

  # Now, create the pull request
  local pr_number
  if ! pr_number=$(create_merge_request "$source_branch" "$target_branch" "$title" | tr -d '\n'); then
    echo -e "${RED}Error: Pull Request creation failed for merging $source_branch into $target_branch.${NC}"
    return 1
  fi
  if [[ -z "$pr_number" ]]; then
    echo -e "${RED}Error: Pull Request creation failed for merging $source_branch into $target_branch.${NC}"
    return 1
  fi

  echo "Waiting up to $wait_time seconds for pull request $pr_number to become mergeable..."
  wait_until_mergeable "$pr_number" "$wait_time"
  local ret=$?

  # Leave these as if statements.  It is clearer that way
  if [ $ret -ne 0 ]; then
    echo -e "${RED}Timeout or error waiting for pull request $pr_number to become mergeable.${NC}"
    return 1
  fi

  # Long-lived release branches are preserved. Temporary automation branches may be deleted.
  trigger_merge "$pr_number" "$delete_source_branch"
  if [ $? -ne 0 ]; then
    echo -e "${RED}Merge trigger failed for PR $pr_number.${NC}"
    return 1
  fi

  if ! poll_merge_status "$pr_number" "$wait_time"; then
    return 1
  fi
  return 0
}

#-----------------------------------------
# Function: get_next_rc_number
# Determines the next available release-candidate (rcX) number.
#
# Arguments:
#   $1 - Release number (e.g., "10.2")
#
# Behavior:
#   - Lists existing Git tags matching the pattern "<release_number>-rcX".
#   - Extracts the numeric portion (X) from those tags.
#   - Finds the highest existing rc number and increments it.
#   - If no matching tags exist, starts at "rc1".
#
# Returns:
#   The next available release candidate tag (e.g., "10.2-rc1", "10.2-rc2").
#-----------------------------------------
get_next_rc_number() {
  local release_number="$1"  # e.g., "10.2"
  local tag_suffix=""
  local tag_regex
  local sed_expression

  if [[ "$BRANCH_ENVIRONMENT" == "PW" ]]; then
    tag_suffix="-pw"
    tag_regex="^${release_number}-rc[0-9]+-pw$"
    sed_expression="s/^${release_number}-rc([0-9]+)-pw$/\1/"
  else
    tag_regex="^${release_number}-rc[0-9]+$"
    sed_expression="s/^${release_number}-rc([0-9]+)$/\1/"
  fi

  git fetch --tags --prune --prune-tags || return 1

  local highest_rc
  highest_rc=$(git tag | grep -E "$tag_regex" | sed -E "$sed_expression" | sort -nr | head -n1)

  if [[ -z "$highest_rc" ]]; then
    echo "${release_number}-rc1${tag_suffix}"
  else
    echo "${release_number}-rc$((highest_rc + 1))${tag_suffix}"
  fi
}
#-----------------------------------------
# Function: generate_changelog
# Generates a changelog for the upcoming release by listing commit
# messages between the most recent official (previous) tag and HEAD.
#
# Behavior:
#   - Finds the most recent tag that follows the format "X.Y" (e.g., "10.2"),
#     excluding pre-release tags like "10.2-rc1".
#   - If a previous tag is found, sets the commit range as "previous_tag..HEAD".
#     Otherwise, uses HEAD as the range.
#   - Retrieves commit messages (excluding merge commits) in reverse chronological order.
#   - Ensures that the 'changelogs' directory exists in the script's original execution location.
#   - Extracts the last segment of <REPO_PROJECT> (after the last '/') for the filename.
#   - Outputs the changelog to "changelogs/<last_part_of_repo_project>_<RELEASE_NUMBER>_changelog.txt".
#
# Returns:
#   0 on success. Also sets the global variable GENERATED_CHANGELOG_COMMITS
#   to the commit list (the same content written to the changelog file,
#   minus the header) so callers can fold it into other output (e.g. GitHub
#   release notes) without it ever going to stdout/terminal/log.
#-----------------------------------------
generate_changelog() {
  # Find the most recent official tag for the selected environment.
  local previous_tag
  if [[ "$BRANCH_ENVIRONMENT" == "PW" ]]; then
    previous_tag=$(git tag | grep -E '^[0-9]+(\.[0-9]+)+-pw$' | sort -V | tail -n1)
  else
    previous_tag=$(git tag | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -n1)
  fi

  local commit_range
  if [ -n "$previous_tag" ]; then
    commit_range="${previous_tag}..HEAD"
  else
    commit_range="HEAD"
  fi

  # Get the date and time of the HEAD commit
  local head_date
  head_date=$(git log -1 --pretty=format:'%ad' --date='format:%Y-%m-%d %H:%M:%S' HEAD)

  # Extract the last part of REPO_PROJECT (everything after the last '/')
  local repo_name
  repo_name=$(basename "$REPO_PROJECT")

  # Ensure the changelogs directory exists in the script's original execution location
  local changelog_dir="${SCRIPT_DIR}/changelogs"
  mkdir -p "$changelog_dir"

  # Define the output file path
  local changelog_file="${changelog_dir}/${repo_name}_${RELEASE_NUMBER}_changelog.txt"

  # Print header for the upcoming release into the changelog file (single line)
  printf "## Changelog for %s %s (%s)\n\n" "$REPO_PROJECT" "$RELEASE_NUMBER" "$head_date" > "$changelog_file"

  # Capture the commit messages (excluding merge commits) once, so the same
  # list can be written to the changelog file and also handed to the caller
  # via a global variable — not stdout, so it never prints to the terminal
  # or the log unless something explicitly echoes it.
  local commit_log
  commit_log=$(git log "$commit_range" --oneline --reverse --no-merges)
  echo "$commit_log" >> "$changelog_file"
  GENERATED_CHANGELOG_COMMITS="$commit_log"

  echo -e "${GREEN}Changelog saved to $changelog_file${NC}"
  return 0
}

#-----------------------------------------
# Function: process_submodules
# Updates the parent repository's submodule pointers to the latest commits on
# the branch that matches the parent target branch.
#
# Arguments:
#   $1 - Parent target branch (for example: ngwpc-candidate, ngwpc-release,
#        or the selected development branch)
#
# Behavior:
#   - Creates a temporary parent branch from origin/<target_branch>.
#   - Initializes and synchronizes all configured submodules.
#   - Fetches origin/<target_branch> in each top-level submodule.
#   - Checks out the exact commit at origin/<target_branch> in detached-HEAD mode.
#   - Commits changed gitlink pointers in the parent repository.
#   - Pushes the temporary branch and merges it into <target_branch> through a PR.
#   - Leaves the parent checked out on the updated target branch with submodules
#     synchronized to the committed pointers.
#
# Safety:
#   - Fails without committing if any submodule does not have the requested branch.
#   - Does not create commits inside submodule repositories.
#   - Nested submodules are initialized recursively, but only top-level gitlink
#     pointers recorded directly by this parent repository are changed.
#-----------------------------------------
process_submodules() {
  local target_branch="$1"
  local previous_branch temp_branch
  local -a submodule_paths=()

  echo -e "${GREEN}Updating submodule pointers for parent branch: $target_branch${NC}"

  if [[ ! -f .gitmodules ]]; then
    echo -e "${YELLOW}has_submodules=true, but this repository has no .gitmodules file. Nothing to update.${NC}"
    return 0
  fi

  mapfile -t submodule_paths < <(
    git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}'
  )

  if (( ${#submodule_paths[@]} == 0 )); then
    echo -e "${YELLOW}No submodule paths were found in .gitmodules. Nothing to update.${NC}"
    return 0
  fi

  previous_branch=$(git rev-parse --abbrev-ref HEAD)
  temp_branch="update_submodules_${target_branch//\//_}_${RELEASE_NUMBER//\//_}"

  if ! git fetch --quiet origin "$target_branch"; then
    echo -e "${RED}Unable to fetch parent target branch origin/$target_branch.${NC}"
    return 1
  fi

  # Always recreate the temporary branch from the current remote target branch.
  git merge --abort >/dev/null 2>&1 || true
  git branch --quiet -D "$temp_branch" >/dev/null 2>&1 || true
  if ! git checkout --quiet -b "$temp_branch" "origin/$target_branch"; then
    echo -e "${RED}Unable to create temporary branch $temp_branch from origin/$target_branch.${NC}"
    return 1
  fi
  TEMP_BRANCHES+=("$temp_branch")

  if ! git submodule sync --recursive; then
    echo -e "${RED}Unable to synchronize submodule URLs.${NC}"
    git checkout --quiet "$previous_branch" || true
    return 1
  fi

  if ! git submodule update --init --recursive; then
    echo -e "${RED}Unable to initialize the repository submodules.${NC}"
    git checkout --quiet "$previous_branch" || true
    return 1
  fi

  local path
  for path in "${submodule_paths[@]}"; do
    echo -e "Updating ${GREEN}$path${NC} to origin/${GREEN}$target_branch${NC}..."

    if [[ ! -d "$path" ]]; then
      echo -e "${RED}Submodule directory does not exist after initialization: $path${NC}"
      git checkout --quiet "$previous_branch" || true
      return 1
    fi

    if ! git -C "$path" fetch --quiet origin "$target_branch"; then
      echo -e "${RED}Unable to fetch origin/$target_branch for submodule $path.${NC}"
      git checkout --quiet "$previous_branch" || true
      return 1
    fi

    if ! git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$target_branch^{commit}" >/dev/null; then
      echo -e "${RED}Submodule $path does not have an origin/$target_branch branch.${NC}"
      git checkout --quiet "$previous_branch" || true
      return 1
    fi

    if ! git -C "$path" checkout --quiet --detach "origin/$target_branch"; then
      echo -e "${RED}Unable to check out origin/$target_branch in submodule $path.${NC}"
      git checkout --quiet "$previous_branch" || true
      return 1
    fi

    echo "  $path -> $(git -C "$path" rev-parse --short HEAD)"
  done

  # Stage only the top-level submodule gitlinks listed in .gitmodules.
  if ! git add -- "${submodule_paths[@]}"; then
    echo -e "${RED}Unable to stage updated submodule pointers.${NC}"
    git checkout --quiet "$previous_branch" || true
    return 1
  fi

  if git diff --cached --quiet; then
    echo -e "${YELLOW}All submodule pointers already match origin/$target_branch. No parent commit is required.${NC}"
    if ! git checkout --quiet "$target_branch"; then
      git checkout --quiet -B "$target_branch" "origin/$target_branch" || return 1
    fi
    git branch --quiet -D "$temp_branch" >/dev/null 2>&1 || true
    git submodule update --init --recursive
    return 0
  fi

  echo "Submodule pointer changes:"
  git diff --cached --submodule=short

  if ! git commit -m "Update submodules for $target_branch release $RELEASE_NUMBER"; then
    echo -e "${RED}Unable to commit updated submodule pointers.${NC}"
    git checkout --quiet "$previous_branch" || true
    return 1
  fi

  if ! git_push --set-upstream origin "$temp_branch"; then
    git checkout --quiet "$previous_branch" || true
    return 1
  fi

  if ! execute_merge_request "$temp_branch" "$target_branch" \
       "Update submodule pointers on $target_branch for release $RELEASE_NUMBER" \
       "$WAIT_TIME" true; then
    echo -e "${RED}Unable to merge updated submodule pointers into $target_branch.${NC}"
    git checkout --quiet "$previous_branch" || true
    return 1
  fi

  if ! git fetch --quiet origin "$target_branch"; then
    echo -e "${RED}Submodule pointer PR merged, but origin/$target_branch could not be fetched.${NC}"
    return 1
  fi

  # Refresh the local parent target branch to the merged remote state.
  if git show-ref --verify --quiet "refs/heads/$target_branch"; then
    if ! git checkout --quiet "$target_branch" || ! git reset --quiet --hard "origin/$target_branch"; then
      echo -e "${RED}Unable to refresh local branch $target_branch after the submodule pointer merge.${NC}"
      return 1
    fi
  else
    if ! git checkout --quiet -b "$target_branch" "origin/$target_branch"; then
      echo -e "${RED}Unable to create local branch $target_branch after the submodule pointer merge.${NC}"
      return 1
    fi
  fi

  if ! git submodule update --init --recursive; then
    echo -e "${RED}Parent branch was updated, but its submodules could not be synchronized to the committed pointers.${NC}"
    return 1
  fi

  echo -e "${GREEN}Submodule pointers on $target_branch were updated successfully.${NC}"
  return 0
}

#-----------------------------------------
# Function: manual_submodule_pause
# Used instead of process_submodules unless --automatic-submodules is set
# (manual is the default). Rather than updating submodule pointers
# automatically, this pauses so the user can update them by hand — via a
# feature branch and PR, since the target branch is protected — then continue.
#
# Arguments:
#   $1 - Branch the repo is currently checked out on (the one whose submodule
#        pointers need updating — e.g. ngwpc-candidate, ngwpc-release, or the
#        selected development branch)
#
# Behavior:
#   - No-ops, like process_submodules, if there's no .gitmodules file.
#   - Otherwise blocks with no timeout (this is a real manual task) until the
#     user presses Enter/C to continue, or chooses (S)kip or (Q)uit, matching
#     the same convention used by the per-repo Continue/Skip/Quit prompt.
#
# Returns: 0 to continue, 1 to skip this repo, 2 if the user chose Quit.
#-----------------------------------------
manual_submodule_pause() {
  local branch="$1"

  if [[ ! -f .gitmodules ]]; then
    echo -e "${YELLOW}has_submodules=true, but this repository has no .gitmodules file. Nothing to update.${NC}"
    return 0
  fi

  echo
  echo -e "${YELLOW}Manual submodule update (pass --automatic-submodules to update pointers automatically instead):${NC}"
  echo -e "This repository is currently checked out on ${GREEN}$branch${NC}."
  echo "'$branch' is protected, so you can't push to it directly. Instead:"
  echo "  1. Create a new branch from here, e.g.: git checkout -b update-submodules-$branch"
  echo "  2. Update each submodule to the commit it should point to, then commit that change."
  echo "  3. Push the new branch, then open and merge a pull request into '$branch'."
  echo "  4. Check '$branch' back out (git checkout $branch && git pull) before continuing below."
  echo

  while true; do
    echo -e "${YELLOW}(C)ontinue once done, (S)kip this repository, (Q)uit:${NC}"
    read -n 1 -s -r user_input
    echo
    user_input="${user_input:-C}"
    user_input=$(echo "$user_input" | tr '[:lower:]' '[:upper:]')
    case "$user_input" in
      C)
        echo -e "${GREEN}Continuing.${NC}"
        return 0
        ;;
      S)
        echo -e "${YELLOW}Skipping this repository.${NC}"
        return 1
        ;;
      Q)
        echo -e "${YELLOW}Quit requested. No further repositories will be processed.${NC}"
        return 2
        ;;
      *)
        echo "Please press C, S, or Q."
        ;;
    esac
  done
}

#-----------------------------------------
# Function: process_repo
# Processes a single repository given its directory, a base release number and release notes.
#
# For RC releases the base number is processed through get_next_rc_number so that RELEASE_NUMBER
# is set (e.g. “10.2-rc1” or “10.2-rc2”). Then, if RELEASE_NUMBER ends with "-rc1" (or if the release
# is OFFICIAL), the script creates an initial merge request from the source branch to the target
# branch. For subsequent RC releases (i.e. not candidate 1), the initial merge is skipped
# (assuming the target branch already has all required changes).  Tagging/release creation still occurs
#
# Arguments:
#   $1 - Repository directory
#   $2 - Base release number (e.g., "1.2")
#   $3 - Release notes
#   $4 - (Optional) has_submodules flag
#   $5 - (Optional) commit_summary — appended to the release notes as a
#        "Commit Summary" section, but only for OFFICIAL releases.
#-----------------------------------------
process_repo() {
  local repo_directory="$1"
  local base_release_number="$2"
  local release_notes="$3"
  local has_submodules="$4"
  local commit_summary="$5"

  local start_time
  start_time=$(date +"%Y-%m-%d %H:%M:%S")
  local start_seconds=$SECONDS  # Capture start time in seconds
  export start_seconds

  TEMP_BRANCHES=()

  echo "----------------------------------------------------------"

  local return_code=0  # Default to success
  local quit_requested=false  # Track if user chose Quit

  # Convert full path to tilde-prefixed path if it starts with $HOME
  if [[ $repo_directory == "$HOME"* ]]; then
    repo_directory_short="~${repo_directory#$HOME}"
  else
    repo_directory_short="$repo_directory"
  fi

  # Expand "~" to $HOME for the actual filesystem path
  if [[ $repo_directory == ~* ]]; then
    repo_directory="${repo_directory/#\~/$HOME}"
  fi

  # If the directory doesn't exist, record a FAILED status and continue
  if [[ ! -d "$repo_directory" ]]; then
    echo -e "${RED}Path does not exist:${NC} $repo_directory"
    # Record a failed entry so the summary table isn't empty
    repo_status["$repo_directory_short"]="$base_release_number | FAILED | 0s | (no repo)"
    repo_order+=("$repo_directory_short")
    return 1
  fi

  # Always cd into the repository before any gh/git calls
  if ! cd "$repo_directory"; then
    echo "Cannot cd to $repo_directory"
    # Record a failed entry so the summary table isn't empty
    repo_status["$repo_directory_short"]="$base_release_number | FAILED | 0s | (cd failed)"
    repo_order+=("$repo_directory_short")
    return 1
  fi

  # Set the global RELEASE_NUMBER based on RELEASE_TYPE
  if [[ "$RELEASE_TYPE" == "RC" ]]; then
    if ! RELEASE_NUMBER=$(get_next_rc_number "$base_release_number"); then
      echo -e "${RED}Unable to determine the next RC tag for $base_release_number.${NC}"
      return 1
    fi
  elif [[ "$BRANCH_ENVIRONMENT" == "PW" && "$RELEASE_TYPE" == "OFFICIAL" ]]; then
    RELEASE_NUMBER="${base_release_number}-pw"
  else
    RELEASE_NUMBER="$base_release_number"
  fi
  export RELEASE_NUMBER

  # We echo here so we can show the full release number.  So technically, we are missing out the timing for the get_next_rc_number
  echo -e "$start_time ${GREEN}Processing repository: $repo_directory (Release: $RELEASE_NUMBER)${NC}"
  echo

  # --- OWP MODE: create ngwpc-<release> (or ngwpc-<release>-pw) branch from $RELEASE_BRANCH and exit ---
  if [ "$RELEASE_TYPE" = "OWP" ]; then
    local new_branch="ngwpc-$base_release_number"
    if [[ "$BRANCH_ENVIRONMENT" == "PW" ]]; then
      new_branch+="-pw"
    fi

    echo -e "${GREEN}OWP mode: Creating branch $new_branch from $RELEASE_BRANCH...${NC}"

    git fetch --quiet origin "$RELEASE_BRANCH"
    git checkout --quiet -b "$new_branch" "origin/$RELEASE_BRANCH"

    if git_push --set-upstream origin "$new_branch"; then
      echo -e "${GREEN}Created and pushed $new_branch successfully.${NC}"
    else
      echo -e "${RED}Failed to push $new_branch.${NC}"
      return 1
    fi

    # Nothing else to do for OWP mode
    return 0
  fi


  echo -e "${YELLOW}Proceed with processing this repository? (C)ontinue, (S)kip, (Q)uit [default: C in 60s]:${NC}"
  read -t 60 -n 1 -s -r user_input
  echo

  # Default to Continue if no input is provided
  user_input="${user_input:-C}"
  user_input=$(echo "$user_input" | tr '[:lower:]' '[:upper:]')

  case "$user_input" in
    Q)
      echo -e "${YELLOW}Quit requested. No release actions will be performed for this repository.${NC}"
      return_code=2
      quit_requested=true
      return
      ;;
    S)
      echo -e "${YELLOW}Skipping this repository.${NC}"
      return 1
      ;;
    C|*)
      echo -e "${GREEN}Continuing with $repo_directory...${NC}"
      ;;
  esac

  # Get the remote URL.
  repo_remote=$(git remote get-url origin)

  # Derive the canonical "owner/repo" once and use it everywhere.
  REPO_PROJECT=$(clean_and_encode_project "$repo_remote")

  echo "Remote URL: $repo_remote"

  # Ensure cleanup_repo always runs when this function returns
  trap "cleanup_repo '$REPO_PROJECT' '$repo_directory_short'; trap - RETURN; if [ \"$quit_requested\" = true ]; then exit 2; fi" RETURN


  # Ensure gh is operating on this repo (sanity)
  if ! run_gh repo view "$REPO_PROJECT" >/dev/null 2>&1; then
    echo -e "${RED}gh cannot determine repository context in $repo_directory. Is this a GitHub repo and are you authenticated?${NC}"
    return_code=1
    return
  fi

  # Fetch the list of tags from the remote repository and check if the release tag already exists.
  local remote_tags
  remote_tags=$(git ls-remote --tags origin | awk '{print $2}' | sed 's#refs/tags/##')
  if echo "$remote_tags" | grep -Fxq "$RELEASE_NUMBER"; then
    echo -e "${RED}Tag '$RELEASE_NUMBER' already exists in the remote repository. Please choose a different release number.${NC}"
    return_code=1
    return
  fi

  # Determine source and target branches *before* handling submodules
  local SOURCE_BRANCH TARGET_BRANCH
  if [ "$RELEASE_TYPE" = "RC" ]; then
    SOURCE_BRANCH="$DEVELOPMENT_BRANCH"
    TARGET_BRANCH="$RELEASE_CANDIDATE_BRANCH"
  else
    SOURCE_BRANCH="$RELEASE_CANDIDATE_BRANCH"
    TARGET_BRANCH="$RELEASE_BRANCH"
  fi

  echo -e "Source branch: ${GREEN}$SOURCE_BRANCH${NC}"
  echo -e "Target branch: ${GREEN}$TARGET_BRANCH${NC}"

  echo -e "Pulling latest updates for branch ${GREEN}${SOURCE_BRANCH}${NC}..."
  if ! git checkout --quiet "$SOURCE_BRANCH" || ! git pull --quiet --ff-only; then
    echo -e "${RED}Unable to update source branch $SOURCE_BRANCH.${NC}"
    return_code=1
    return
  fi

  # Perform the merge request for the initial RC1 or Official release
  if [ "$RELEASE_TYPE" = "OFFICIAL" ] || [[ "$RELEASE_NUMBER" =~ -rc1(-pw)?$ ]]; then
    if ! execute_merge_request "$SOURCE_BRANCH" "$TARGET_BRANCH" \
         "Merge $SOURCE_BRANCH into $TARGET_BRANCH for release $RELEASE_NUMBER" "$WAIT_TIME"; then
      return_code=1
      return
    fi
  else
    # For subsequent RC releases, we assume that TARGET_BRANCH already has all needed changes.
    echo -e "${YELLOW}Subsequent RC (> RC1) release detected. Skipping merge from $SOURCE_BRANCH.${NC}"
  fi

  # Pull the latest updates for the target branch.
  echo -e "Pulling latest updates for branch ${GREEN}$TARGET_BRANCH${NC}..."
  if ! git checkout --quiet "$TARGET_BRANCH" || ! git pull --quiet --ff-only; then
    echo -e "${RED}Unable to update target branch $TARGET_BRANCH.${NC}"
    return_code=1
    return
  fi
  echo

  if [ "$has_submodules" = "true" ]; then
    if [ "$AUTOMATIC_SUBMODULES" = "true" ]; then
      echo "Calling process_submodules for $TARGET_BRANCH"
      if ! process_submodules "$TARGET_BRANCH"; then
        return_code=1
        return
      fi
    else
      manual_submodule_pause "$TARGET_BRANCH"
      local pause_rc=$?
      if [ "$pause_rc" -eq 2 ]; then
        quit_requested=true
        return_code=2
        return
      elif [ "$pause_rc" -ne 0 ]; then
        return_code=1
        return
      fi
    fi
  fi

  # Create changelog for OFFICIAL releases
  local commit_log=""
  GENERATED_CHANGELOG_COMMITS=""
  if [ "$RELEASE_TYPE" = "OFFICIAL" ]; then
    echo
    # Generate the changelog for the current release tag.
    echo "Generating changelog for tag $RELEASE_NUMBER:"
    generate_changelog
    commit_log="$GENERATED_CHANGELOG_COMMITS"
  fi

  # For OFFICIAL releases only, append a "Commit Summary" section (if the
  # config provided one) followed by a "Change Log" section (the commit list
  # generate_changelog just produced).
  local final_release_notes="$release_notes"
  if [ "$RELEASE_TYPE" = "OFFICIAL" ]; then
    if [ -n "$commit_summary" ]; then
      final_release_notes="${final_release_notes}

Commit Summary

${commit_summary}"
    fi
    if [ -n "$commit_log" ]; then
      final_release_notes="${final_release_notes}

Change Log

${commit_log}"
    fi
  fi

  # Create GitHub release
  echo -e "${GREEN}Creating GitHub release for $REPO_PROJECT $RELEASE_NUMBER...${NC}"
  if ! create_release "$RELEASE_NUMBER" "Release $RELEASE_NUMBER" "$final_release_notes" "$TARGET_BRANCH"; then
    echo -e "${RED}Error: GitHub release creation for $REPO_PROJECT $RELEASE_NUMBER failed.${NC}"
    return_code=1
    return
  fi

  # Merge the completed release branch back into the selected development branch.
  if [[ "$RELEASE_TYPE" == "OFFICIAL" || ( "$RELEASE_TYPE" == "RC" && ! "$RELEASE_NUMBER" =~ -rc1(-pw)?$ ) ]]; then
    if ! execute_merge_request "$TARGET_BRANCH" "$DEVELOPMENT_BRANCH" \
      "Merge $TARGET_BRANCH into $DEVELOPMENT_BRANCH for release $RELEASE_NUMBER" "$WAIT_TIME"; then
      echo -e "${RED}Release was created, but merge-back into $DEVELOPMENT_BRANCH failed.${NC}"
      return_code=1
      return
    fi
  fi

  # If submodules exist, update their pointers for the selected development branch
  if [ "$has_submodules" = "true" ]; then
    if [ "$AUTOMATIC_SUBMODULES" = "true" ]; then
      echo "Setting submodules to $DEVELOPMENT_BRANCH"
      if ! process_submodules "$DEVELOPMENT_BRANCH"; then
        return_code=1
        return
      fi
    else
      manual_submodule_pause "$DEVELOPMENT_BRANCH"
      local pause_rc=$?
      if [ "$pause_rc" -eq 2 ]; then
        quit_requested=true
        return_code=2
        return
      elif [ "$pause_rc" -ne 0 ]; then
        return_code=1
        return
      fi
    fi
  fi

  echo -e "Pulling latest updates for branch ${GREEN}${SOURCE_BRANCH}${NC}"
  git checkout --quiet "$SOURCE_BRANCH" && git pull --quiet
  echo

  if [ "$SOURCE_BRANCH" != "$DEVELOPMENT_BRANCH" ]; then
    echo -e "Pulling latest updates for branch ${GREEN}$DEVELOPMENT_BRANCH${NC}..."
    git checkout --quiet "$DEVELOPMENT_BRANCH" && git pull --quiet
    echo
  fi

  echo -e "Pulling latest updates for branch ${GREEN}$TARGET_BRANCH${NC}..."
  git checkout --quiet "$TARGET_BRANCH" && git pull --quiet
  echo

  return "$return_code"
}

#-----------------------------------------
# Function: cleanup_repo
# Cleans up temporary branches and logs the processing status for the current repository.
#
# Behavior:
#   - Checks out the selected development branch and pulls the latest changes.
#   - Retrieves the latest commit hash for the repository.
#   - Records the release number, processing status (SUCCESS or FAILED), elapsed time,
#     and commit hash in a global associative array.
#   - Iterates through the TEMP_BRANCHES array, deleting each temporary branch locally
#     and remotely (if it exists).
#   - Adds the repository to a global order list and prints a final message with the elapsed time.
#   - Sets a global return code variable (GLOBAL_RETURN_CODE) to reflect the overall status.
#-----------------------------------------
cleanup_repo() {
  local repo_project="$1"   # e.g., owner/repo
  local repo_short="$2"     # the "~..." path you passed in trap

  local exit_code=$return_code  # Preserve the return code
  local end_time
  end_time=$(date +"%Y-%m-%d %H:%M:%S")
  local elapsed_seconds=$(( SECONDS - start_seconds ))

  # Park on the selected development branch when possible, but do not let cleanup overwrite the release result.
  git merge --abort >/dev/null 2>&1 || true
  git checkout --quiet "$DEVELOPMENT_BRANCH" >/dev/null 2>&1 || true
  git pull --quiet --ff-only >/dev/null 2>&1 || true

  # Retrieve the latest commit hash when the directory is still a valid repository.
  local latest_commit_hash
  latest_commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "(unavailable)")

  # Store status, elapsed time, and commit hash in the global array
  local status="FAILED"
  if [ "$return_code" -eq 0 ]; then
    status="SUCCESS"
  elif [ "$return_code" -eq 2 ]; then
    status="QUIT"
  fi

  # Key by the short path you passed in
  repo_status["$repo_short"]="$RELEASE_NUMBER | $status | ${elapsed_seconds}s | $latest_commit_hash"

  # Iterate through TEMP_BRANCHES and delete them
  for temp_branch in "${TEMP_BRANCHES[@]}"; do
    # Local: match either "* " (current) or "  " (not current) then the exact branch name
    if git branch --list | grep -qE "^[* ]\s*${temp_branch}$"; then
      echo "Deleting local branch: $temp_branch"
      git branch -D "$temp_branch" >/dev/null 2>&1 || true
    fi

    # Remote
    if git ls-remote --heads origin "$temp_branch" | grep -q "$temp_branch"; then
      echo "Deleting remote branch: $temp_branch"
      git_push origin --delete "$temp_branch" || true
    fi
  done

  repo_order+=("$repo_short")
  echo -e "$end_time ${GREEN}Finished processing: $repo_project ($repo_short)${NC} (Elapsed time: $elapsed_seconds seconds)"

  # Simply returning the return code doesn't see to work.  Need to use a global variable.  It might be Trap that is getting in the way
  # Only latch this repo's code in when it actually failed/quit — otherwise a
  # later repo succeeding would silently clear an earlier repo's failure and
  # the script's final exit code would say everything was fine.
  if [ "$exit_code" -ne 0 ]; then
    GLOBAL_RETURN_CODE=$exit_code
  fi
}

# Summary function to print repo statuses

# Global associative array to store repository status
declare -A repo_status
# Global array to store repository order
repo_order=()

print_summary() {
  local longest_repo_name=0
  local total_elapsed_seconds=$(( SECONDS - ${total_seconds:-$SECONDS} ))

  # Determine the longest repository name from the repo_order array
  for repo in "${repo_order[@]}"; do
    if (( ${#repo} > longest_repo_name )); then
      longest_repo_name=${#repo}
    fi
  done

  # Column widths
  local repo_column_width=$((longest_repo_name + 2)) # Add extra padding
  local release_column_width=15
  local status_column_width=10
  local time_column_width=6
  local commit_column_width=40 # Adjust based on hash length
  local total_width=$((repo_column_width + release_column_width + status_column_width + time_column_width + commit_column_width + 13))

  # Define summary file path
  local summary_file="${SCRIPT_DIR}/release_summary.txt"

  # Print header to console and file
  printf "\n%-${repo_column_width}s | %-${release_column_width}s | %-${status_column_width}s | %-${time_column_width}s | %-${commit_column_width}s\n" \
    "Repository" "Release" "Status" "Time" "Commit Hash" | tee "$summary_file"
  printf -- "%-${total_width}s\n" | tr ' ' '-' | tee -a "$summary_file"

  # Print repository details in the order they were processed
  for repo in "${repo_order[@]}"; do
    IFS='|' read -r release status time commit_hash <<< "${repo_status[$repo]}"
    printf "%-${repo_column_width}s | %-15s | %-10s | %-6s | %-40s\n" \
      "$repo" "$release" "$status" "$time" "$commit_hash" | tee -a "$summary_file"
  done

  # Print footer
  printf -- "%-${total_width}s\n" | tr ' ' '-' | tee -a "$summary_file"
  echo "All repositories processed (Total elapsed time: ${total_elapsed_seconds} seconds)." | tee -a "$summary_file"

  echo -e "${GREEN}Summary saved to: ${summary_file}${NC}"
}

#-----------------------------------------
# Function: main
# Prompts for the release type, displays a list of repositories that will be processed
# (marking those with the skip flag), and asks the user to confirm whether to continue.
# Then, it loops through the JSON file and processes each repository that is not skipped.
#-----------------------------------------
main() {
  total_seconds=$SECONDS  # start of the whole process
  # Remember where we were executed from
  SCRIPT_DIR="$(pwd)"

  RELEASE_TYPE=""
  json_file="createReleaseConfig.json"
  WAIT_TIME="60"
  BRANCH_ENVIRONMENT="STANDARD"
  AUTOMATIC_SUBMODULES=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--release-type)
        [[ $# -ge 2 ]] || { echo -e "${RED}Missing value for $1.${NC}"; exit 1; }
        RELEASE_TYPE="$2"
        shift 2
        ;;
      -c|--config)
        [[ $# -ge 2 ]] || { echo -e "${RED}Missing value for $1.${NC}"; exit 1; }
        json_file="$2"
        shift 2
        ;;
      -v|--verbose)
        DEBUG_GH=true
        shift 1
        ;;
      -w|--wait-time)
        [[ $# -ge 2 ]] || { echo -e "${RED}Missing value for $1.${NC}"; exit 1; }
        WAIT_TIME="$2"
        shift 2
        ;;
      -e|--environment)
        [[ $# -ge 2 ]] || { echo -e "${RED}Missing value for $1.${NC}"; exit 1; }
        BRANCH_ENVIRONMENT="$2"
        shift 2
        ;;
      -a|--automatic-submodules)
        AUTOMATIC_SUBMODULES=true
        shift 1
        ;;
      -h|--help|?)
        usage
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo -e "${RED}Unknown option: $1${NC}"
        echo
        usage 1
        ;;
      *)
        echo -e "${RED}Unexpected argument: $1${NC}"
        echo
        usage 1
        ;;
    esac
  done

  # Start logging everything to a file
  LOGFILE="createRelease_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee >(sed -r "s/\x1B\[[0-9;]*[mK]//g" >> "$LOGFILE")) 2>&1
  echo "All output will be logged to: $LOGFILE"

  if [[ -z "$RELEASE_TYPE" ]]; then
    echo -e "${RED}--release-type is required.${NC}"
    echo
    usage 1
  fi

  RELEASE_TYPE=$(echo "$RELEASE_TYPE" | tr '[:lower:]' '[:upper:]')
  if [[ "$RELEASE_TYPE" != "OFFICIAL" && "$RELEASE_TYPE" != "RC" && "$RELEASE_TYPE" != "OWP" ]]; then
    echo -e "${RED}Invalid release type. Use RC, OFFICIAL, or OWP.${NC}"
    exit 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo -e "${RED}Required git command missing. Ensure git is installed.${NC}"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Required jq command missing. Ensure jq installed.${NC}"
    exit 1
  fi

  if ! command -v sed >/dev/null 2>&1; then
    echo -e "${RED}Required commands sed missing. Ensure sed installed.${NC}"
    exit 1
  fi

  # Ensure gh is installed/authed
  if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}The GitHub CLI (gh) is not installed. Please install and run 'gh auth login'.${NC}"
    exit 1
  fi
  
  # Status is informational; use wrapper for consistent "Executing:" line (may be redirected away).
  if ! run_gh auth status; then
    echo -e "${RED}GitHub CLI authentication is not valid. Run 'gh auth login' and try again.${NC}"
    exit 1
  fi

  if [ ! -f "$json_file" ]; then
    echo -e "${RED}JSON file $json_file not found.${NC}"
    echo
    usage 1
  fi

  # Validate JSON before doing anything else
  if ! jq empty "$json_file" >/dev/null 2>&1; then
    echo -e "${RED}Error: JSON file '$json_file' is invalid and could not be parsed.${NC}"
    echo -e "${YELLOW} jq reported a syntax error. Fix the JSON and try again.${NC}"
    exit 1
  fi
  if [[ "$(jq -r 'type' "$json_file")" != "array" ]]; then
    echo -e "${RED}Error: JSON configuration must contain a top-level array.${NC}"
    exit 1
  fi

  # Validate the optional per-repo "env" field: must be PW, AWS, ALL, or absent
  # (absent defaults to ALL, so existing configs without this field keep working
  # under every -e environment).
  validation_repo_count=$(jq length "$json_file")
  for (( vi=0; vi<validation_repo_count; vi++ )); do
    repo_env_check=$(jq -r ".[$vi].env // \"ALL\"" "$json_file" | tr '[:lower:]' '[:upper:]')
    case "$repo_env_check" in
      PW|AWS|ALL) ;;
      *)
        bad_repo_dir=$(jq -r ".[$vi].repo_directory" "$json_file")
        echo -e "${RED}Error: invalid \"env\" value '$repo_env_check' for repo_directory '$bad_repo_dir' (entry $vi). Must be PW, AWS, or ALL.${NC}"
        exit 1
        ;;
    esac
  done

  if [[ ! "$WAIT_TIME" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}WAIT_TIME must be a positive integer number of seconds.${NC}"
    exit 1
  fi
  echo "Wait time for merges is $WAIT_TIME seconds"
  if [ "$AUTOMATIC_SUBMODULES" = "true" ]; then
    echo -e "${YELLOW}Submodule updates: automatic${NC}"
  else
    echo -e "${YELLOW}Submodule updates: manual (pass --automatic-submodules to update pointers automatically instead)${NC}"
  fi

  BRANCH_ENVIRONMENT=$(echo "$BRANCH_ENVIRONMENT" | tr '[:lower:]' '[:upper:]')
  case "$BRANCH_ENVIRONMENT" in
    DEFAULT|STANDARD|AWS)
      BRANCH_ENVIRONMENT="STANDARD"
      DEVELOPMENT_BRANCH="development"
      RELEASE_CANDIDATE_BRANCH="ngwpc-candidate"
      RELEASE_BRANCH="ngwpc-release"
      ;;
    PW|PARALLEL-WORKS|PARALLEL_WORKS)
      BRANCH_ENVIRONMENT="PW"
      DEVELOPMENT_BRANCH="development-pw"
      RELEASE_CANDIDATE_BRANCH="ngwpc-candidate-pw"
      RELEASE_BRANCH="ngwpc-release-pw"
      ;;
    *)
      echo -e "${RED}Invalid environment '$BRANCH_ENVIRONMENT'. Use STANDARD or PW.${NC}"
      exit 1
      ;;
  esac

  echo "Branch environment: $BRANCH_ENVIRONMENT"
  echo "  Development branch:       $DEVELOPMENT_BRANCH"
  echo "  Release candidate branch: $RELEASE_CANDIDATE_BRANCH"
  echo "  Release branch:           $RELEASE_BRANCH"

  echo -e "${GREEN}Reading from $json_file${NC}"
  echo

  # Read JSON data once and display the list of repos that will be processed
  json_data=$(cat "$json_file")
  repo_count=$(echo "$json_data" | jq length)

  echo -e "${GREEN}The following repositories will be processed:${NC}"
  for (( i=0; i<repo_count; i++ )); do
    repo_directory=$(echo "$json_data" | jq -r ".[$i].repo_directory")
    release=$(echo "$json_data" | jq -r ".[$i].release")
    # Read the skip flag (default to false)
    skip=$(echo "$json_data" | jq -r ".[$i].skip // false")
    # Read the env field (default to ALL, so configs without it run everywhere)
    repo_env=$(echo "$json_data" | jq -r ".[$i].env // \"ALL\"" | tr '[:lower:]' '[:upper:]')

    display_dir="$repo_directory"
    resolved_dir="$repo_directory"
    if [[ $resolved_dir == ~* ]]; then
      resolved_dir="${resolved_dir/#\~/$HOME}"
    fi
    exists_note=""
    if [[ ! -d "$resolved_dir" ]]; then
      exists_note=" ${RED}(missing)${NC}"
    fi

    if [ "$skip" = "true" ]; then
      echo -e "${YELLOW}Repo: $display_dir (Release: $release) (skipping)${NC}${exists_note}"
    elif ! repo_env_applies "$repo_env"; then
      echo -e "${YELLOW}Repo: $display_dir (Release: $release) (skipping: env=$repo_env doesn't apply under -e $BRANCH_ENVIRONMENT)${NC}${exists_note}"
    else
      echo -e "${GREEN}Repo: $display_dir (Release: $release)${NC}${exists_note}"
    fi
  done

  echo
  echo -n "Proceed with processing these repositories? (Y/N): "
  read -r confirm
  confirm=$(echo "$confirm" | tr '[:lower:]' '[:upper:]')
  if [ "$confirm" != "Y" ]; then
    echo "Aborting."
    exit 0
  fi

  # Loop through each repository and process it (skip if flag is true)
  GLOBAL_RETURN_CODE=0
  for (( i=0; i<repo_count; i++ )); do
    repo_directory=$(echo "$json_data" | jq -r ".[$i].repo_directory")
    release=$(echo "$json_data" | jq -r ".[$i].release")

    release_notes=$(echo "$json_data" | jq -r ".[$i].release_notes // \"\"")
    commit_summary=$(echo "$json_data" | jq -r ".[$i].commit_summary // \"\"")
    has_submodules=$(echo "$json_data" | jq -r ".[$i].has_submodules // false")  # Default to false
    skip=$(echo "$json_data" | jq -r ".[$i].skip // false")  # Default to false
    repo_env=$(echo "$json_data" | jq -r ".[$i].env // \"ALL\"" | tr '[:lower:]' '[:upper:]')  # Default to ALL

    # Expand tilde if present.
    if [[ $repo_directory == ~* ]]; then
      repo_directory="${repo_directory/#\~/$HOME}"
    fi

    if [ "$skip" = "true" ]; then
      echo -e "${YELLOW}Skipping repository: $repo_directory (Release: $release)${NC}"
      continue
    fi

    if ! repo_env_applies "$repo_env"; then
      echo -e "${YELLOW}Skipping repository: $repo_directory (Release: $release) — env=$repo_env doesn't apply under -e $BRANCH_ENVIRONMENT${NC}"
      continue
    fi

    process_repo "$repo_directory" "$release" "$release_notes" "$has_submodules" "$commit_summary"

    # If user selected Quit, exit the loop
    if [ "${GLOBAL_RETURN_CODE:-0}" -eq 2 ]; then
      echo "User chose to quit. Exiting script."
      break
    fi
  done

  print_summary
  exit "${GLOBAL_RETURN_CODE:-0}"
}

main "$@"
