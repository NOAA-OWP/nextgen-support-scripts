# genCandidateCommitList.py

## Overview

`genCandidateCommitList.py` generates a readable text file containing commits **after a specified date** for each repository listed in `createReleaseConfig.json` where `"skip": false`.

This script is designed for **candidate release preparation** and mirrors the behavior of `findMerges.sh`:

- Uses `origin/development` by default
- Includes **merge commits by default**
- Filters commits using `--after <date>`
- Processes only repositories where `"skip": false`

The output is structured for:
- Human readability
- Easy ingestion into ChatGPT for release note summarization
- Validation of expected repository changes

---

## Requirements

- Python 3.9+
- Git installed and available in PATH
- All repositories cloned locally

---

## Basic Usage

```bash
python genCandidateCommitList.py -a "2026-03-12" -o candidateReleaseCommits.txt
```

---

## Arguments

| Argument | Required | Default | Description |
|----------|--------:|---------|-------------|
| `-a`, `--after` | ✅ | — | Include commits after this date/time |
| `-o`, `--output` | ✅ | — | Output text file |
| `-c`, `--config` | ❌ | `createReleaseConfig.json` | Config file |
| `-t`, `--target-ref` | ❌ | `origin/development` | Git ref to inspect |
| `--no-fetch` | ❌ | false | Skip `git fetch origin development` |

---

## Date Format Examples

```bash
-a "2026-03-12"
-a "2026-03-12 15:30:00"
-a "2026-03-12 15:30:00 -0500"
```

---

## Behavior Details

### Default Behavior

- Uses:
  ```bash
  git log origin/development --after=<date>
  ```
- Includes **merge commits**
- Matches behavior of:
  ```bash
  findMerges.sh --mode any
  ```

---

## Output Structure

### Header Summary

Includes:

- Total repositories in config
- Repositories processed (`skip: false`)
- Repositories with commits
- Repositories without commits
- Repositories with warnings
- Missing or invalid repositories

---

### Repository Lists (Top Section)

```text
Repositories With Commits
-------------------------
  - repo1
  - repo2

Repositories Without Commits
----------------------------
  - repoX
  - repoY
```

---

### Per-Repository Sections

Each repository includes:

- Repo name
- Local path
- Branch
- Target ref
- Commit count
- Commit list

Example:

```text
========================================================================================
Repository: ngen
========================================================================================
Commit Count          : 3

Commits:
  - abc123 | 2026-03-13 | Dev | Fix logging
  - def456 | 2026-03-13 | Dev | Add feature
```

---

## Console Output

At completion:

```text
Repositories processed      : 27
Repositories w/commits      : 27
Repositories w/o commits    : 0
```

Also prints:

```text
Repositories WITHOUT commits:
  - repo-name
```

---

## Common Issues

### 1. Missing Repositories

If a repo is not cloned:

```text
WARNING: Skipped because repository directory does not exist.
```

---

### 2. Branch Mismatch

Script checks:

```bash
origin/development
```

If commits exist elsewhere (e.g., local branch), they will not appear.

---

### 3. Merge Commit Confusion

Merge commits are included by default.

To verify:

```bash
git show <commit>
```

Look for:

```text
Merge: <hash1> <hash2>
```

---

## Recommended Workflow

1. Run:
   ```bash
   findMerges.sh
   ```
2. Set `"skip": false` for relevant repos
3. Run:
   ```bash
   genCandidateCommitList.py
   ```
4. Upload output file to ChatGPT
5. Generate release notes

---

## Notes

- This script intentionally mirrors `findMerges.sh`
- Designed for reproducible release candidate validation
- Output format is optimized for summarization workflows

---

## License

Internal / project-specific tooling
