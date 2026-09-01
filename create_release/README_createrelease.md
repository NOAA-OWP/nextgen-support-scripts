# createRelease.sh — Documentation

This document describes how to use `createRelease.sh` to automate GitHub releases (release candidates, official releases, and OWP branch cuts) across one or more repositories. It covers prerequisites, the JSON configuration file format, command-line options, interactive prompts, and troubleshooting.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [JSON Configuration File](#json-configuration-file)

   * [Required Fields](#required-fields)
   * [Optional Fields](#optional-fields)
   * [Sample JSON](#sample-json)
4. [Command-Line Usage](#command-line-usage)

   * [Options](#options)
   * [Help Flag](#help-flag)
5. [Environment Branch Model](#environment-branch-model)

   * [Per-Repo `env` Targeting](#per-repo-env-targeting)
6. [Release Types](#release-types)

   * [RC — Release Candidate](#rc--release-candidate)
   * [OFFICIAL](#official)
   * [OWP — Branch Only](#owp--branch-only)
7. [Submodule Handling](#submodule-handling)
8. [Interactive Prompts](#interactive-prompts)
9. [What Happens Per Repository](#what-happens-per-repository)
10. [Cleanup, Logging & Summary](#cleanup-logging--summary)
11. [Exit Codes](#exit-codes)
12. [Examples](#examples)
13. [Troubleshooting](#troubleshooting)

---

## Overview

`createRelease.sh` automates the end-to-end release workflow for GitHub repositories, including:

* Merging one release branch into the next (`development` → `ngwpc-candidate` → `ngwpc-release`) via pull requests
* Waiting for a PR to become mergeable and triggering the merge (direct merge, falling back to auto-merge)
* Updating submodule pointers to match the parent repo's release branch — automatically, or pausing for you to do it by hand (the default) — *before* the release below is created
* Generating a changelog for OFFICIAL releases
* Tagging and creating GitHub releases (pre-release for RC, official for OFFICIAL)
* Merging completed release branches back into `development`, then updating `development`'s submodule pointers the same way — automatically, or pausing for you to do it by hand (the default)
* Cutting standalone OWP branches for submission upstream
* Producing a per-repo summary table and log file

The script reads a JSON file listing one or more repository entries. For each entry it determines source/target branches from `--release-type`, merges as needed, handles submodules for the target branch, generates a changelog (OFFICIAL only), tags and creates the GitHub release, merges back into `development`, handles submodules again for `development`, cleans up temporary branches, and records a status line for the final summary.

---

## Prerequisites

1. **Bash** on a Unix-like system (Linux, macOS, WSL).
2. **`git`**, **`jq`**, and **`sed`** on `PATH`.
3. **GitHub CLI (`gh`)**, installed and authenticated (`gh auth login`). The script checks `gh auth status` at startup and exits if it isn't valid.
4. A working local clone of each `repo_directory` listed in the JSON file, with an `origin` remote pointing to the GitHub repo (HTTPS or SSH).
5. Network access to `github.com`.
6. If a repository uses submodules and you want them updated automatically (`--automatic-submodules`), the submodule's own repo needs a branch with the exact same name as whichever parent branch is being updated (`development`, `development-pw`, `ngwpc-candidate`, `ngwpc-candidate-pw`, `ngwpc-release`, `ngwpc-release-pw`) already pushed to its origin. The script follows an existing same-named branch in the submodule — it does not create one there for you.

---

## JSON Configuration File

The script expects a JSON array of objects, one per "release job." Default filename: `createReleaseConfig.json` (override with `-c`/`--config`).

### Required Fields

* **`repo_directory`** — Path to the local clone. A leading `~` is expanded to `$HOME`.
* **`release`** — Base version string (e.g. `"10.9"`). For `RC`, the script computes the next `-rcX` suffix automatically. For `OFFICIAL`, this is used verbatim (plus a `-pw` suffix under the PW environment). Ignored for `OWP` other than to name the branch (`ngwpc-<release>`).

### Optional Fields

* **`release_notes`** (string, default `""`) — Body text for the GitHub release.
* **`commit_summary`** (string, default `""`) — For `OFFICIAL` releases only: appended to the release notes under a "Commit Summary" heading, ahead of the auto-generated "Change Log" section.
* **`has_submodules`** (boolean, default `false`) — If `true`, the script updates this repo's submodule pointers after each merge (see [Submodule Handling](#submodule-handling)). If the repo has no `.gitmodules` file, this is a harmless no-op.
* **`skip`** (boolean, default `false`) — If `true`, the repo is listed as "(skipping)" and never processed, regardless of `env`.
* **`env`** (string: `PW`, `AWS`, or `ALL`; default `ALL`) — Restricts which `-e`/`--environment` run this entry is processed under, independent of `skip`. See [Environment Branch Model](#environment-branch-model) for the full breakdown.

### Sample JSON

```json
[
  {
    "repo_directory": "~/sandbox/test_repo1",
    "release": "10.9",
    "release_notes": "Implement feature XYZ\nFixed bug #123"
  },
  {
    "repo_directory": "~/sandbox/test_repo_sub1",
    "release": "10.4",
    "release_notes": "Initial RC for module ABC",
    "skip": true
  },
  {
    "repo_directory": "~/sandbox/test_repo2",
    "release": "10.5",
    "release_notes": "Stabilize integration with other repos",
    "commit_summary": "Bumped the parser dependency and updated the ngen submodule.",
    "has_submodules": true
  },
  {
    "repo_directory": "~/sandbox/pw_only_repo",
    "release": "10.5",
    "release_notes": "Parallel Works specific fix",
    "env": "PW"
  }
]
```

* The first entry gets processed normally.
* The second is marked `"skip": true` — listed, but never touched.
* The third has submodules — its pointers get updated per whatever `--automatic-submodules` mode is in effect. `commit_summary` only shows up in the release notes for an `OFFICIAL` run.
* The fourth only runs under `-e PW`; it's silently skipped ("env=PW doesn't apply under -e STANDARD") on a `STANDARD` run.

---

## Command-Line Usage

```
./createRelease.sh --release-type <RC|OFFICIAL|OWP> [OPTIONS]
```

### Options

| Flag | Required | Description | Default |
|---|---|---|---|
| `-r`, `--release-type TYPE` | **Yes** | `RC`, `OFFICIAL`, or `OWP` (case-insensitive) | — |
| `-c`, `--config FILE` | No | Path to the JSON config file | `createReleaseConfig.json` |
| `-v`, `--verbose` | No | Print the exact `gh` commands being executed (to stderr) | `false` |
| `-w`, `--wait-time SECONDS` | No | Max seconds to wait for a PR to become mergeable, and (separately) max seconds to wait for a triggered merge to actually complete, before giving up | `60` |
| `-e`, `--environment ENV` | No | `STANDARD` or `PW` — selects the branch set (see [Environment Branch Model](#environment-branch-model)) | `STANDARD` |
| `-a`, `--automatic-submodules` | No | Update submodule pointers automatically instead of pausing for a manual update | `false` (manual) |
| `-h`, `--help` | No | Show usage and exit | — |

`STANDARD` also accepts `AWS` or `DEFAULT`; `PW` also accepts `PARALLEL-WORKS` or `PARALLEL_WORKS` — all case-insensitive.

### Help Flag

```bash
./createRelease.sh --help
```
or
```bash
./createRelease.sh -h
```

---

## Environment Branch Model

The script never touches `main`/`master` directly — it works across three long-lived release branches per environment:

| | STANDARD | PW |
|---|---|---|
| Development | `development` | `development-pw` |
| Release candidate | `ngwpc-candidate` | `ngwpc-candidate-pw` |
| Release | `ngwpc-release` | `ngwpc-release-pw` |

Release tags follow the same pattern:

| | STANDARD | PW |
|---|---|---|
| RC | `10.2-rc1` | `10.2-rc1-pw` |
| OFFICIAL | `10.2` | `10.2-pw` |

If `ngwpc-candidate` or `ngwpc-release` (or their `-pw` counterparts) don't exist yet on a given repo, the script creates them from the appropriate source branch the first time they're needed — no PR, just a direct push, since there's nothing to review yet.

### Per-Repo `env` Targeting

Which of the above two branch sets a given config entry actually runs under is controlled by its optional `env` field (`PW`, `AWS`, or `ALL`; default `ALL`), independent of `skip`:

| `env` value | Processed under `-e STANDARD` | Processed under `-e PW` |
|---|---|---|
| `ALL` (or omitted) | yes | yes |
| `AWS` | yes | no |
| `PW` | no | yes |

This lets one config file serve both deployment targets — entries that only apply to one platform (AWS vs. Parallel Works) are simply tagged accordingly, and everything else keeps running under every `-e` the same as before this field existed.

---

## Release Types

### RC — Release Candidate

* **First RC (`-rc1`) for a release:** merges `development` → `ngwpc-candidate` via PR (creating `ngwpc-candidate` from `development` first if it doesn't exist), updates `ngwpc-candidate`'s submodule pointers if `has_submodules`, then tags and creates a GitHub **pre-release** on `ngwpc-candidate`.
* **Subsequent RCs (`-rc2`, `-rc3`, ...):** skips the merge from `development` (assumes `ngwpc-candidate` already has what it needs), updates submodule pointers if applicable, tags and creates the next pre-release, **then merges `ngwpc-candidate` back into `development`** and updates `development`'s submodule pointers if applicable.
* The next RC number is determined automatically from existing tags matching `<release>-rcN[-pw]`.
* A submodule-pointer-update failure on the merge-back fails that step only — the RC pre-release already created is **not** rolled back.

### OFFICIAL

* Merges `ngwpc-candidate` → `ngwpc-release` via PR (creating `ngwpc-release` first if needed), updates submodule pointers if applicable, generates a changelog (commit log since the last official tag, written to `changelogs/<repo>_<release>_changelog.txt`), tags and creates the **official** GitHub release on `ngwpc-release`, then **always** merges `ngwpc-release` back into `development` and updates `development`'s submodule pointers if applicable — regardless of RC-vs-`rc1` rules, since there's no `-rc1` concept for OFFICIAL.
* A submodule-pointer-update failure on the merge-back fails that step only — the official release already created is **not** rolled back.

### OWP — Branch Only

* Creates `ngwpc-<release>` (or `ngwpc-<release>-pw` under PW) directly from `ngwpc-release` and pushes it. No PR, no tag, no GitHub release.
* This branch is what eventually gets submitted as a pull request to the upstream NOAA OWP parent repository — the script only prepares and pushes it; it does **not** open that PR.

---

## Submodule Handling

Controlled by `has_submodules` in the config entry, and by whether `--automatic-submodules` was passed:

* **`has_submodules: false`** (or omitted) — nothing happens; submodules are ignored entirely.
* **`has_submodules: true`, no `--automatic-submodules` (the default)** — the script **pauses** at each point it would otherwise update pointers (see below) and prints instructions: since the target branch is protected against direct pushes, create a new branch from it, update each submodule to the commit it should point to, commit, push that branch, and open+merge a PR into the target branch — then check the target branch back out, and press **C** to continue, **S** to skip this repo, or **Q** to quit the whole run. There's no timeout on this prompt; it's a real manual task.
* **`has_submodules: true`, with `--automatic-submodules`** — the script does it for you: fetches the submodule's same-named branch, checks it out (detached), stages the updated gitlink(s), and if anything actually changed, commits, pushes a temporary branch, and merges it into the parent branch via PR. If a repo's `.gitmodules` file doesn't exist, this is a silent no-op either way.

This happens at **two points** per repo, whichever mode is active:

1. Right after merging into the target branch (`ngwpc-candidate` for RC, `ngwpc-release` for OFFICIAL) — on every RC run, not just `-rc1`.
2. Right after merging the target branch back into `development` — on RC2+ and every OFFICIAL run (not RC1, since RC1 doesn't merge back).

---

## Interactive Prompts

| Prompt | When | Options | Timeout |
|---|---|---|---|
| `Proceed with processing these repositories? (Y/N):` | Once, after listing all configured repos | Y / N | none |
| `Proceed with processing this repository? (C)ontinue, (S)kip, (Q)uit` | Once per repo, before touching it | C / S / Q | 60s → defaults to C |
| `Pull Request N not ready (state: ...). (C)ontinue waiting, (S)kip:` | Only if a PR is still not mergeable after `--wait-time` seconds | C / S | none once triggered — but only appears at all on a real terminal; under non-interactive stdin it skips straight to failing instead of prompting |
| `(C)ontinue once done, (S)kip this repository, (Q)uit:` — preceded by: `Manual submodule update (pass --automatic-submodules to update pointers automatically instead): This repository is currently checked out on <branch>. '<branch>' is protected, so you can't push to it directly. Instead: 1. Create a new branch from here... 2. Update each submodule and commit. 3. Push the new branch, then open and merge a PR into '<branch>'. 4. Check '<branch>' back out before continuing below.` | Manual submodule update pause (see above) | C / S / Q | none |

---

## What Happens Per Repository

For each non-skipped, environment-matching entry (see [Per-Repo `env` Targeting](#per-repo-env-targeting)), `process_repo` roughly does the following. Everything below is written using the `STANDARD` branch names for readability — under `-e PW`, every branch mentioned is automatically its `-pw` counterpart instead (`development-pw`, `ngwpc-candidate-pw`, `ngwpc-release-pw`):

1. **Determine `RELEASE_NUMBER`** — for `RC`, via `get_next_rc_number`; for `OFFICIAL` under PW, `<release>-pw`; otherwise `<release>` verbatim.
2. **OWP short-circuit** — if `--release-type OWP`, create/push the branch and return; nothing below applies.
3. **Per-repo C/S/Q prompt**, then confirm `gh` can see the repo and that `RELEASE_NUMBER` isn't already an existing tag.
4. **Determine source/target branches** — `development`→`ngwpc-candidate` for RC, `ngwpc-candidate`→`ngwpc-release` for OFFICIAL (or their `-pw` counterparts under `-e PW`, per above).
5. **Merge source → target** (skipped for RC2+, which assumes the target already has what it needs). The merge does a local no-commit merge test first to catch conflicts before ever opening a PR — a conflict confined to submodule gitlinks (paths matching `extern/*`) is allowed through to let the PR resolve it per repo rules; any other conflict blocks the PR entirely and fails the repo.
6. **Submodule pointer update** on the target branch, automatic or manual per above.
7. **Changelog generation** (OFFICIAL only) — commit log since the last tag matching `X.Y` (or `X.Y-pw`), written to `changelogs/<repo>_<release>_changelog.txt`, and folded into the release notes under a "Change Log" heading (after "Commit Summary", if `commit_summary` was provided).
8. **Create the GitHub release** — pre-release for RC, official for OFFICIAL.
9. **Merge target → `development`** (RC2+ and every OFFICIAL run).
10. **Submodule pointer update** on `development`, automatic or manual per above.
11. Return to source/target/development branches, pulling latest, before moving to the next repo.

---

## Cleanup, Logging & Summary

* **Per-repo cleanup** always runs (via a shell `trap`), regardless of success or failure: checks out `development`, records status (`SUCCESS` / `FAILED` / `QUIT`), elapsed time, and latest commit hash, then deletes any temporary branches created for that repo (`merge_test_*`, `update_submodules_*`) both locally and on origin.
* **Logging** — everything printed goes to `createRelease_<timestamp>.log` in the current directory (ANSI color codes stripped), in addition to the terminal.
* **Summary** — after all repos are processed (or Quit is chosen), a table is printed and written to `release_summary.txt`:

  ```
  Repository                | Release       | Status     | Time   | Commit Hash
  ----------------------------------------------------------------------------------------
  ~/sandbox/test_repo1     | 10.9-rc1      | SUCCESS    |  42s   | abcdef1234567890...
  ~/sandbox/test_repo2     | 10.5          | FAILED     |  30s   | 123456abcdef7890...
  ----------------------------------------------------------------------------------------
  All repositories processed (Total elapsed time: 75 seconds).
  ```

---

## Exit Codes

* **`0`** — every processed repo succeeded.
* **`1`** — at least one repo ended FAILED. This latches: a later repo succeeding does not clear an earlier failure.
* **`2`** — Quit was chosen at some point (per-repo prompt or a manual-submodule pause), and the remaining repos were never processed.

---

## Examples

```bash
# Basic RC release, default config file, manual submodule updates
./createRelease.sh --release-type RC

# Official release with a custom config file
./createRelease.sh --release-type OFFICIAL --config release_config.json

# RC under the Parallel Works environment, with a longer PR-wait budget
./createRelease.sh --release-type RC --config release_config.json --wait-time 120 --environment PW

# Cut an OWP branch under PW
./createRelease.sh --release-type OWP --environment PW

# RC with submodule pointers updated automatically instead of pausing
./createRelease.sh --release-type RC --automatic-submodules

# See the exact gh commands being run, for debugging
./createRelease.sh --release-type RC --verbose
```

---

## Troubleshooting

* **`JSON file <filename> not found.`** — Check `--config`, or the default `createReleaseConfig.json` in the current directory.

* **`Error: JSON file '<file>' is invalid and could not be parsed.`** — Fix the JSON; verify with `jq . <file>`.

* **`Error: JSON configuration must contain a top-level array.`** — The file must be a JSON array (`[ {...}, {...} ]`), not a single object.

* **`Error: invalid "env" value '<value>' for repo_directory '<dir>' (entry N). Must be PW, AWS, or ALL.`** — Fix the `env` field on that config entry; this is checked for every entry before any repo is touched.

* **`WAIT_TIME must be a positive integer number of seconds.`** — `--wait-time` must be a plain positive integer.

* **`Invalid environment '<value>'. Use STANDARD or PW.`** — See the accepted aliases in [Options](#options).

* **`gh cannot determine repository context in <dir>. Is this a GitHub repo and are you authenticated?`** — Run `gh auth status` in that repo; confirm `origin` points to GitHub.

* **`Tag '<release>' already exists in the remote repository.`** — Pick a different `release` value, or confirm you didn't already run this release.

* **`Merge has conflicts outside submodules. Pull request will not be created.`** — A real conflict, not just a submodule-pointer mismatch. Resolve manually on the source/target branch, push, and re-run.

* **`Submodule <path> does not have an origin/<branch> branch.`** — Under `--automatic-submodules`, the submodule's own repo needs a branch with that exact name pushed to its origin first — the script follows an existing branch, it doesn't create one.

* **`Error triggering merge for PR N.`** followed by `Direct merge attempt said: ...` / `Auto-merge attempt said: ...`** — Both merge strategies failed; the two "said" lines show `gh`'s actual error for each attempt (a required check, branch protection, an existing conflict, etc.).

* **`Gave up waiting for pull request N to complete after <wait-time>s (last state: ...).`** — The merge was triggered (often via auto-merge) but never actually completed within `--wait-time`. Common cause: a required status check that never reports on a repo with no CI configured. Increase `--wait-time`, or check the PR directly.

* **`GraphQL: Base branch was modified. Review and try the merge again.`** — A transient GitHub race, most often seen when merging PRs against the same repo in quick succession; simply re-running the merge shortly after usually succeeds.

* **`PR N still not mergeable after <wait-time>s; stdin isn't a terminal, so skipping instead of prompting.`** — Expected when running non-interactively (e.g. automation, CI, or the regression harness); on a real terminal this would instead offer a Continue/Skip prompt.

* **Repository shows FAILED in the summary but the script exited 0 in an older run** — Fixed: the script's own exit code now reflects whether any repo failed (see [Exit Codes](#exit-codes)).

* **Skipped repositories** — Check the pre-flight list: `"skip": true` shows as `(skipping)`; an `env` mismatch shows as `(skipping: env=... doesn't apply under -e ...)`.
