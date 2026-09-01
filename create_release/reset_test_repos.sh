#!/usr/bin/env bash
#
# reset_test_repos.sh — puts the release-script sandbox repos back into a
#                       known baseline before a full regression run.
#
# Default (safe) mode: checks out development, fast-forwards it, prunes
#                      stale remote-tracking branches.
#
# --nuke mode: additionally deletes ngwpc-candidate, ngwpc-release, their
#              -pw counterparts, any ngwpc-<ver>[-pw] OWP branches, and any leftover
#              merge_test_*/update_submodules_*/test-update-* temp branches — both locally and on
#              origin — plus any tags matching the test release patterns used by
#              regression_test.py (bases starting with "0.0.") AND the GitHub releases
#              (pre-release or official) associated with those tags. Use this when you
#              want every scenario (including "create candidate from scratch") to run
#              as if from a clean history.
#
# Requires the GitHub CLI (`gh`, authenticated) to delete releases. If `gh`
# isn't available, --nuke still removes the tags themselves but leaves any
# associated GitHub releases in place (with a warning).
#
# ORG RULE: any branch whose name starts with "ngwpc" cannot be deleted on
#           origin (org-level protection), so --nuke can only remove those branches
#          locally — the remote copies are left in place and reported as such.
#          development-pw is never nuked at all (local or remote) — like
#          development, it's a persistent source branch (ngwpc-candidate-pw is
#          created from it), not a release artifact. The merge_test_*/
#          update_submodules_*/test-update-* temp branches are still deleted both locally and
#          remotely, same as always.
#          If the ngwpc-* branches on origin need clearing, that currently has to be
#          done manually (e.g. by someone with admin/bypass rights).
#
# Usage:
#   ./reset_test_repos.sh [--nuke] [<repo_dir> ...]
#
#    With no <repo_dir> arguments, defaults to the three sandbox repos as
#    subdirectories of the current directory: peter_test1, peter_test2,
#    peter_test_sub1.

set -euo pipefail


usage() {
  cat <<EOF
Usage: $0 [--nuke] [<repo_dir> ...]
 
With no <repo_dir> arguments, defaults to the three sandbox repos as
subdirectories of the current directory: peter_test1, peter_test2,
peter_test_sub1.
 
Default (safe) mode: checks out development, fast-forwards it, prunes
stale remote-tracking branches.
 
--nuke mode: additionally deletes ngwpc-candidate, ngwpc-release, their
-pw counterparts, any ngwpc-<ver>[-pw] OWP branches, and any leftover
merge_test_*/update_submodules_*/test-update-* temp branches -- both locally and on
origin -- plus any tags matching the test release patterns used by
regression_test.py (bases starting with "0.0.") AND the GitHub releases
(pre-release or official) associated with those tags.
 
Options:
  --nuke       Also remove candidate/release branches, OWP branches, test
               tags, and their GitHub releases (see above)
  -h, --help   Show this help and exit
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

NUKE=false
if [[ "${1:-}" == "--nuke" ]]; then
  NUKE=true
  shift
fi

if [[ $# -eq 0 ]]; then
  set -- peter_test1 peter_test2 peter_test_sub1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

GH_AVAILABLE=true
if ! command -v gh >/dev/null 2>&1; then
  GH_AVAILABLE=false
  echo "Warning: 'gh' not found on PATH — GitHub releases for nuked test tags will be left in place (only the tags themselves will be removed)." >&2
fi

BRANCHES_TO_NUKE=(ngwpc-candidate ngwpc-release ngwpc-candidate-pw ngwpc-release-pw)

# delete_branch <branch>
# Always deletes the branch locally. Only attempts remote deletion if the
# branch name doesn't start with "ngwpc" — those are protected by org policy
# and the push --delete would just be rejected, so we don't pretend it worked.
delete_branch() {
  local b="$1"
  git branch -D "$b" >/dev/null 2>&1 || true

  if [[ "$b" == ngwpc* ]]; then
    echo "  deleted local branch $b (remote copy left in place — ngwpc-* branches can't be deleted on origin per org policy)"
  else
    if git push origin --delete "$b" >/dev/null 2>&1; then
      echo "  deleted branch $b (local+remote)"
    else
      echo "  deleted local branch $b (remote delete failed or branch wasn't on origin)"
    fi
  fi
}

for repo_dir in "$@"; do
  echo "== $repo_dir =="
  (
    cd "$repo_dir"

    git fetch --all --prune --prune-tags --quiet

    git checkout --quiet development
    git pull --quiet --ff-only origin development

    # Always clear out leftover temp branches from interrupted runs.
    for b in $(git branch --list 'merge_test_*' 'update_submodules_*' 'test-update-*' | tr -d ' *'); do
      echo "  deleting stale local temp branch $b"
      git branch -D "$b" >/dev/null 2>&1 || true
    done
    for b in $(git ls-remote --heads origin | awk '{print $2}' | sed 's#refs/heads/##' | grep -E '^(merge_test_|update_submodules_|test-update-)' || true); do
      echo "  deleting stale remote temp branch $b"
      git push origin --delete "$b" >/dev/null 2>&1 || true
    done

    if [[ "$NUKE" == true ]]; then
      for b in "${BRANCHES_TO_NUKE[@]}"; do
        delete_branch "$b"
      done

      # Remove OWP branches (ngwpc-<something not candidate/release>)
      for b in $(git ls-remote --heads origin | awk '{print $2}' | sed 's#refs/heads/##' | grep -E '^ngwpc-[0-9]' || true); do
        delete_branch "$b"
      done

      # Remove test-release tags (bases used by regression_test.py start with
      # 0.0.) and their associated GitHub releases (pre-release or official).
      for t in $(git tag -l '0.0.*'); do
        if [[ "$GH_AVAILABLE" == true ]]; then
          if gh release delete "$t" --yes >/dev/null 2>&1; then
            echo "  deleted GitHub release $t"
          else
            echo "  no GitHub release found for tag $t (or delete failed)"
          fi
        fi
        git tag -d "$t" >/dev/null 2>&1 || true
        git push origin ":refs/tags/$t" >/dev/null 2>&1 || true
        echo "  removed tag $t"
      done
    fi
  )
done

echo "Done."
