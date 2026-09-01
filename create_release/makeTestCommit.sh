#!/usr/bin/env bash
#
# makeTestCommit.sh
#
# Creates a throwaway feature branch off a given base branch in a given
# repository, updates foo.txt with a fresh date stamp, commits, pushes,
# opens a GitHub pull request merging the feature branch into the base
# branch, merges that PR, then deletes the feature branch both locally and
# on GitHub. Requires the GitHub CLI (`gh`), authenticated, since the base
# branch is protected and can't be pushed to directly.
#
# Usage:
#   ./makeTestCommit.sh -r <repo_directory> -b <base_branch>
#
# Example:
#   ./makeTestCommit.sh --repo-directory peter-test2 --base-branch development

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat <<EOF

Usage: $(basename "$0") -r <repo_directory> -b <base_branch>

  -r, --repo-directory DIR   Path to the local git repository (relative or absolute)
  -b, --base-branch BRANCH   Branch to base the feature branch on, and merge back into
  -h, --help                 Show this help and exit

Example:
  $(basename "$0") --repo-directory peter-test2 --base-branch development
EOF
}

REPO_DIR=""
BASE_BRANCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -r|--repo-directory)
      REPO_DIR="$2"
      shift 2
      ;;
    -b|--base-branch)
      BASE_BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Error: unknown argument '$1'.${NC}" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$REPO_DIR" ] || [ -z "$BASE_BRANCH" ]; then
  echo -e "${RED}Error: both --repo-directory and --base-branch are required.${NC}" >&2
  usage
  exit 1
fi

if ! command -v gh > /dev/null 2>&1; then
  echo -e "${RED}Error: GitHub CLI ('gh') is required but not found.${NC}" >&2
  exit 1
fi

if ! gh auth status > /dev/null 2>&1; then
  echo -e "${RED}Error: 'gh' is not authenticated. Run 'gh auth login' first.${NC}" >&2
  exit 1
fi

ORIGINAL_DIR="$(pwd)"
FEATURE_BRANCH="test-update-${BASE_BRANCH}-$(date +%Y%m%d%H%M%S)"

# Always return to the starting directory, even on failure.
cleanup() {
  cd "$ORIGINAL_DIR"
}
trap cleanup EXIT

if [ ! -d "$REPO_DIR" ]; then
  echo -e "${RED}Error: repository directory '$REPO_DIR' does not exist.${NC}" >&2
  exit 1
fi

cd "$REPO_DIR"

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo -e "${RED}Error: '$REPO_DIR' is not a git repository.${NC}" >&2
  exit 1
fi

echo -e "${YELLOW}Repository:${NC} $(pwd)"
echo -e "${YELLOW}Base branch:${NC} $BASE_BRANCH"
echo -e "${YELLOW}Feature branch:${NC} $FEATURE_BRANCH"
echo

echo -e "${YELLOW}Checking out and updating '$BASE_BRANCH'...${NC}"
git checkout "$BASE_BRANCH"
git pull origin "$BASE_BRANCH"

echo -e "${YELLOW}Creating feature branch '$FEATURE_BRANCH'...${NC}"
git checkout -b "$FEATURE_BRANCH"

echo -e "${YELLOW}Updating foo.txt...${NC}"
echo "Test update from $FEATURE_BRANCH" >> foo.txt

git add foo.txt
git commit -m "Test commit: update foo.txt on $(date)"

echo -e "${YELLOW}Pushing '$FEATURE_BRANCH' to origin...${NC}"
git push -u origin "$FEATURE_BRANCH"

echo -e "${YELLOW}Opening pull request: '$FEATURE_BRANCH' -> '$BASE_BRANCH'...${NC}"
git checkout "$BASE_BRANCH"
PR_URL=$(gh pr create \
  --base "$BASE_BRANCH" \
  --head "$FEATURE_BRANCH" \
  --title "Test commit: update foo.txt on $BASE_BRANCH" \
  --body "Automated test commit created by makeTestCommit.sh")
echo "  $PR_URL"

echo -e "${YELLOW}Merging pull request...${NC}"
MERGE_ATTEMPTS=5
for attempt in $(seq 1 "$MERGE_ATTEMPTS"); do
  if gh pr merge "$FEATURE_BRANCH" --merge --delete-branch; then
    break
  fi
  if [ "$attempt" -eq "$MERGE_ATTEMPTS" ]; then
    echo -e "${RED}Error: failed to merge PR after $MERGE_ATTEMPTS attempts.${NC}" >&2
    exit 1
  fi
  echo -e "${YELLOW}Merge attempt $attempt failed (likely GitHub still settling the base ref) — retrying in 5s...${NC}"
  sleep 5
done

echo -e "${YELLOW}Pulling latest '$BASE_BRANCH' and pruning stale branches...${NC}"
git pull --prune origin "$BASE_BRANCH"

echo -e "${YELLOW}Deleting local feature branch (if still present)...${NC}"
git branch -d "$FEATURE_BRANCH" 2>/dev/null || true

if [ -f .gitmodules ]; then
  echo -e "${YELLOW}Updating submodules to match merged pointers...${NC}"
  git submodule update --init --recursive
fi

echo
echo -e "${GREEN}Done.${NC} New commit merged into '$BASE_BRANCH' in '$REPO_DIR'."
