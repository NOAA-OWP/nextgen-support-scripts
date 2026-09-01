#!/usr/bin/env python3
"""
regression_test.py — drives createRelease.sh against the real sandbox repos
and asserts on the resulting git/gh state.

This runs the ACTUAL script against ACTUAL GitHub repos (peter_test1,
peter_test2, peter_test_sub1). There is no mocking of `gh`/`git` — the
whole point is to exercise the real merge/conflict/submodule logic. Each
scenario uses a fresh timestamp-based release base (e.g. "0.0.1737400000")
so re-runs never collide with a previous run's tags.

Usage:
    # from a directory containing createRelease.sh, peter_test1, peter_test2,
    # and peter_test_sub1 (all default to cwd-relative paths):
    python3 regression_test.py

    # or override any of them, and/or run a subset of scenario groups:
    python3 regression_test.py --script /path/to/createRelease.sh \
        --repo1 /path/to/peter_test1 \
        --repo2 /path/to/peter_test2 \
        --sub1  /path/to/peter_test_sub1 \
        [--scenario rc,official,owp,submodule,config | --scenario all]

        NOTE: scenario submodule has known failures due to NGWPC GitHub branch 
        protecion policies. The createRelease.sh script has been defaulted
        to manually updating the submodule references to ensure any conflicts
        are addressed.
Requires: gh authenticated, git, jq all on PATH (same prereqs as the script
itself). Run reset_test_repos.sh first if you want a clean slate.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field


@dataclass
class Result:
    name: str
    passed: bool
    detail: str = ""
    log_path: str = ""


RESULTS: list[Result] = []

# Directory (relative to run_cwd) where per-check transcripts are written.
# Set from main() once run_cwd is known; falls back to cwd if record() is
# ever called before main() sets it (shouldn't happen in normal use).
LOG_DIR_NAME = "regression_logs"
_log_root = None

# Every sh()/git() call since the last record() lands here, then gets
# flushed to that check's log file and cleared. This means the buffer
# for any given record() call contains exactly the commands that led to
# that particular verdict — nothing from earlier checks, nothing from
# later ones.
_command_log: list[dict] = []


def _slug(name):
    return re.sub(r"[^a-zA-Z0-9]+", "_", name).strip("_").lower()[:80]


def _flush_check_log(name):
    """Write the buffered commands for this check to its own log file and
    return (log_path, tail_text). Clears the buffer either way."""
    global _command_log
    buf, _command_log = _command_log, []
    if not buf:
        return "", ""

    root = _log_root or os.getcwd()
    log_dir = os.path.join(root, LOG_DIR_NAME)
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{_slug(name)}.log")

    sections = []
    all_lines = []
    for i, entry in enumerate(buf, 1):
        header = f"=== command {i}: {entry['args']} (cwd={entry['cwd']}) — exit {entry['returncode']} ==="
        piece = [header]
        if entry["stdout"]:
            piece.append("--- stdout ---")
            piece.append(entry["stdout"].rstrip("\n"))
            all_lines += [l for l in entry["stdout"].splitlines() if l.strip()]
        if entry["stderr"]:
            piece.append("--- stderr ---")
            piece.append(entry["stderr"].rstrip("\n"))
            all_lines += [l for l in entry["stderr"].splitlines() if l.strip()]
        sections.append("\n".join(piece))

    with open(log_path, "w") as f:
        f.write("\n\n".join(sections) + "\n")

    tail = "\n".join(all_lines[-15:])
    return log_path, tail


def record(name, passed, detail=""):
    log_path, tail = _flush_check_log(name)
    RESULTS.append(Result(name, passed, detail, log_path))
    status = "PASS" if passed else "FAIL"
    line = f"[{status}] {name}" + (f" — {detail}" if detail else "")
    print(line)
    if not passed:
        if log_path:
            print(f"    full transcript: {os.path.basename(log_path)}")
        if tail:
            print("    last output:")
            for l in tail.splitlines():
                print(f"      {l}")


def sh(args, cwd=None, input_text=None, timeout=300, check=False):
    """Run a command, returning CompletedProcess with captured text output.
    A timeout is turned into a CompletedProcess with returncode 124 (rather
    than left to raise) so the caller's normal pass/fail checks just see it
    as a failure and record() still runs under the real check name — with
    whatever output the killed process had already produced preserved in
    its log, instead of being lost to an uncaught exception."""
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        proc = subprocess.CompletedProcess(
            args=args,
            returncode=124,
            stdout=(exc.stdout or "") + f"\n[harness] timed out after {timeout}s and was killed\n",
            stderr=exc.stderr or "",
        )
    _command_log.append({
        "args": args,
        "cwd": cwd,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    })
    if check and proc.returncode != 0:
        raise RuntimeError(f"{args} failed:\n{proc.stdout}\n{proc.stderr}")
    return proc


def git(repo_dir, *args, check=True):
    return sh(["git", "-C", repo_dir, *args], check=check)


def remote_tag_exists(repo_dir, tag):
    out = git(repo_dir, "ls-remote", "--tags", "origin", tag).stdout
    return tag in out


def remote_branch_exists(repo_dir, branch):
    out = git(repo_dir, "ls-remote", "--heads", "origin", branch).stdout
    return bool(out.strip())


def branch_merged_into(repo_dir, ancestor_branch, descendant_branch):
    """True if origin/ancestor_branch is an ancestor of origin/descendant_branch."""
    git(repo_dir, "fetch", "--quiet", "origin", ancestor_branch, descendant_branch)
    proc = sh(
        ["git", "-C", repo_dir, "merge-base", "--is-ancestor",
         f"origin/{ancestor_branch}", f"origin/{descendant_branch}"]
    )
    return proc.returncode == 0


def changelog_path(script_cwd, repo_project_name, release_number):
    return os.path.join(script_cwd, "changelogs", f"{repo_project_name}_{release_number}_changelog.txt")


def submodule_paths(repo_dir):
    """Top-level submodule paths declared in repo_dir's checked-out .gitmodules."""
    proc = sh(["git", "config", "--file", ".gitmodules", "--get-regexp",
               r"^submodule\..*\.path$"], cwd=repo_dir, check=True)
    return [line.split()[1] for line in proc.stdout.splitlines() if line.strip()]


def submodule_gitlink_sha(repo_dir, branch, submodule_path):
    """The commit SHA recorded as the gitlink for submodule_path on
    origin/branch — read straight from the tree, no local submodule
    checkout required. Returns None if the branch or path isn't found."""
    git(repo_dir, "fetch", "--quiet", "origin", branch)
    out = git(repo_dir, "ls-tree", f"origin/{branch}", "--", submodule_path).stdout.strip()
    parts = out.split()
    return parts[2] if len(parts) >= 3 else None


# Branches the submodule repo (peter_test_sub1) must already have for the
# pointer-update scenarios below to exercise the real commit/merge path
# instead of erroring out mid-run. createRelease.sh only follows a
# same-named branch in the submodule as it does in the parent — it never
# creates these for you.
REQUIRED_SUBMODULE_BRANCHES = [
    "development", "development-pw",
    "ngwpc-candidate", "ngwpc-candidate-pw",
    "ngwpc-release", "ngwpc-release-pw",
]


def missing_submodule_branches(sub_repo_dir):
    return [b for b in REQUIRED_SUBMODULE_BRANCHES if not remote_branch_exists(sub_repo_dir, b)]


class Harness:
    def __init__(self, script, run_cwd, repo1, repo2, sub1, make_commit_script=None):
        self.script = script
        self.run_cwd = run_cwd  # directory to invoke the script from (config paths are relative to this)
        self.repo1 = repo1
        self.repo2 = repo2
        self.sub1 = sub1
        self.make_commit_script = make_commit_script or os.path.join(
            os.path.dirname(script), "makeTestCommit.sh")

    def make_submodule_commit(self, base_branch):
        """Pushes and merges a throwaway commit onto base_branch in the
        submodule repo via makeTestCommit.sh, so that branch has a new HEAD
        guaranteed to differ from whatever's currently recorded as a
        submodule pointer anywhere else. Returns the new commit SHA."""
        sh([self.make_commit_script, "-r", self.sub1, "-b", base_branch],
           timeout=300, check=True)
        return git(self.sub1, "rev-parse", f"origin/{base_branch}").stdout.strip()

    def write_config(self, entries):
        fd, path = tempfile.mkstemp(suffix=".json", dir=self.run_cwd)
        with os.fdopen(fd, "w") as f:
            json.dump(entries, f, indent=2)
        return path

    def run_release(self, release_type, entries, extra_args=None, confirm="Y\n",
                     per_repo_input="C\n" * 10, wait_time=30, environment="STANDARD",
                     timeout=60):
        """
        Invokes createRelease.sh. `per_repo_input` is repeated stdin fed after
        the initial Y/N confirmation to answer the per-repo (C/S/Q) prompt and
        any wait_until_mergeable (C/S) prompts, so the run doesn't sit idle.

        `timeout` is the harness's own hard kill ceiling for the whole
        invocation — separate from `wait_time`, which is createRelease.sh's
        own --wait-time budget for polling a PR. Most runs finish in well
        under a minute; if one hasn't by then, that's worth failing fast on
        rather than sitting through a long hang, since it's usually a sign
        something (e.g. a merge stuck waiting on a check that will never
        report) needs a look rather than more patience.
        """
        config_path = self.write_config(entries)
        args = [
            self.script,
            "--release-type", release_type,
            "--config", os.path.basename(config_path),
            "--wait-time", str(wait_time),
            "--environment", environment,
        ]
        if extra_args:
            args += extra_args
        proc = sh(args, cwd=self.run_cwd, input_text=confirm + per_repo_input, timeout=timeout)
        return proc, config_path

    def base_release(self, tag="0"):
        """Unique per-scenario release base so tags never collide across runs."""
        return f"0.0.{int(time.time())}{tag}"


# ---------------------------------------------------------------------------
# Argument / config validation scenarios (no repos touched)
# ---------------------------------------------------------------------------

def test_help(h: Harness):
    proc = sh([h.script, "--help"], cwd=h.run_cwd)
    ok = proc.returncode == 0 and "Usage:" in proc.stdout
    record("help text", ok, f"exit={proc.returncode}")


def test_missing_release_type(h: Harness):
    proc = sh([h.script], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "release-type is required" in proc.stdout
    record("missing --release-type", ok)


def test_invalid_release_type(h: Harness):
    proc = sh([h.script, "-r", "FOO"], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "Invalid release type" in proc.stdout
    record("invalid --release-type", ok)


def test_missing_config_file(h: Harness):
    proc = sh([h.script, "-r", "RC", "-c", "does-not-exist.json"], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "not found" in proc.stdout
    record("missing config file", ok)


def test_malformed_json(h: Harness):
    path = os.path.join(h.run_cwd, "broken.json")
    with open(path, "w") as f:
        f.write("{ this is not valid json")
    proc = sh([h.script, "-r", "RC", "-c", os.path.basename(path)], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "could not be parsed" in proc.stdout
    record("malformed JSON config", ok)


def test_non_array_json(h: Harness):
    path = os.path.join(h.run_cwd, "notarray.json")
    with open(path, "w") as f:
        json.dump({"not": "an array"}, f)
    proc = sh([h.script, "-r", "RC", "-c", os.path.basename(path)], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "top-level array" in proc.stdout
    record("non-array JSON config", ok)


def test_bad_wait_time(h: Harness):
    proc = sh([h.script, "-r", "RC", "-w", "notanumber"], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "positive integer" in proc.stdout
    record("non-numeric --wait-time", ok)


def test_bad_environment(h: Harness):
    proc = sh([h.script, "-r", "RC", "-e", "MARS"], cwd=h.run_cwd)
    ok = proc.returncode != 0 and "Invalid environment" in proc.stdout
    record("invalid --environment", ok)


def test_bad_repo_env_field(h: Harness):
    entries = [{"repo_directory": h.repo1, "release": h.base_release("z"), "env": "MARS"}]
    proc, _ = h.run_release("RC", entries, confirm="", per_repo_input="")
    ok = proc.returncode != 0 and "Must be PW, AWS, or ALL" in proc.stdout
    record("invalid per-repo env value rejected", ok)


# ---------------------------------------------------------------------------
# Config-loop behavior scenarios
# ---------------------------------------------------------------------------

def test_missing_repo_directory(h: Harness):
    entries = [{"repo_directory": "/tmp/definitely-does-not-exist",
                "release": h.base_release("a")}]
    proc, _ = h.run_release("RC", entries)
    ok = "FAILED" in proc.stdout and "does not exist" in proc.stdout.replace("Path does not exist:", "does not exist")
    record("missing repo_directory recorded as FAILED", ok)


def test_skip_flag(h: Harness):
    entries = [{"repo_directory": h.repo1, "release": h.base_release("b"), "skip": True}]
    proc, _ = h.run_release("RC", entries)
    ok = "(skipping)" in proc.stdout and "Skipping repository" in proc.stdout
    record("skip:true entry is skipped", ok)


def test_confirmation_abort(h: Harness):
    entries = [{"repo_directory": h.repo1, "release": h.base_release("c")}]
    proc, _ = h.run_release("RC", entries, confirm="N\n", per_repo_input="")
    ok = proc.returncode == 0 and "Aborting." in proc.stdout
    record("confirmation prompt N aborts cleanly", ok)


def test_env_pw_skipped_under_standard(h: Harness):
    entries = [{"repo_directory": h.repo1, "release": h.base_release("k"), "env": "PW"}]
    proc, _ = h.run_release("RC", entries, environment="STANDARD")
    ok = (
        "env=PW doesn't apply under -e STANDARD" in proc.stdout
        and "Skipping repository" in proc.stdout
    )
    record("env=PW repo skipped under -e STANDARD", ok)


def test_env_aws_skipped_under_pw(h: Harness):
    entries = [{"repo_directory": h.repo1, "release": h.base_release("l"), "env": "AWS"}]
    proc, _ = h.run_release("RC", entries, environment="PW")
    ok = (
        "env=AWS doesn't apply under -e PW" in proc.stdout
        and "Skipping repository" in proc.stdout
    )
    record("env=AWS repo skipped under -e PW", ok)


def test_env_all_runs_under_both(h: Harness):
    base = h.base_release("m")
    entries = [{"repo_directory": h.repo1, "release": base, "env": "ALL"}]
    proc_std, _ = h.run_release("RC", entries, environment="STANDARD")
    proc_pw, _ = h.run_release("RC", entries, environment="PW")
    ok = (
        proc_std.returncode == 0 and "Skipping repository" not in proc_std.stdout
        and proc_pw.returncode == 0 and "Skipping repository" not in proc_pw.stdout
    )
    record("env=ALL repo processed under both -e STANDARD and -e PW", ok)


def test_env_absent_defaults_to_all(h: Harness):
    base = h.base_release("n")
    entries = [{"repo_directory": h.repo1, "release": base}]  # no "env" field
    proc, _ = h.run_release("RC", entries, environment="PW")
    ok = proc.returncode == 0 and "Skipping repository" not in proc.stdout
    record("repo with no env field defaults to ALL (runs under PW too)", ok)


# ---------------------------------------------------------------------------
# RC workflow
# ---------------------------------------------------------------------------

def test_rc_lifecycle(h: Harness):
    base = h.base_release("d")
    entries = [{"repo_directory": h.repo1, "release": base}]

    proc1, _ = h.run_release("RC", entries)
    rc1_ok = (
        proc1.returncode == 0
        and remote_tag_exists(h.repo1, f"{base}-rc1")
        and remote_branch_exists(h.repo1, "ngwpc-candidate")
    )
    record("RC1 creates ngwpc-candidate and tags -rc1", rc1_ok,
           f"exit={proc1.returncode}")

    proc2, _ = h.run_release("RC", entries)
    rc2_ok = (
        proc2.returncode == 0
        and "Subsequent RC (> RC1)" in proc2.stdout
        and remote_tag_exists(h.repo1, f"{base}-rc2")
        and branch_merged_into(h.repo1, "ngwpc-candidate", "development")
    )
    record("RC2 skips merge, tags -rc2, merges back to development", rc2_ok,
           f"exit={proc2.returncode}")

    # Immediate third run with zero new commits should be a no-op merge,
    # not a hard failure.
    proc3, _ = h.run_release("RC", entries)
    noop_ok = proc3.returncode == 0
    record("RC no-op run does not error when there's nothing new", noop_ok,
           f"exit={proc3.returncode}")


def test_rc_duplicate_tag_rejected(h: Harness):
    base = h.base_release("e")
    entries = [{"repo_directory": h.repo1, "release": base}]
    h.run_release("RC", entries)  # creates -rc1
    proc, _ = h.run_release("RC", entries)  # get_next_rc_number should give rc2, not a dup — so
    # to actually test duplicate rejection we need the exact same RELEASE_NUMBER twice.
    # The script derives RELEASE_NUMBER from tags automatically for RC, so instead
    # verify OFFICIAL's exact-tag path, which uses base_release_number verbatim.
    entries_official = [{"repo_directory": h.repo1, "release": base}]
    proc_off1, _ = h.run_release("OFFICIAL", entries_official)
    proc_off2, _ = h.run_release("OFFICIAL", entries_official)
    ok = "already exists" in proc_off2.stdout
    record("duplicate release tag rejected on second OFFICIAL run", ok)


def test_rc_pw_environment(h: Harness):
    base = h.base_release("f")
    entries = [{"repo_directory": h.repo1, "release": base}]
    proc, _ = h.run_release("RC", entries, environment="PW")
    ok = (
        proc.returncode == 0
        and remote_tag_exists(h.repo1, f"{base}-rc1-pw")
        and remote_branch_exists(h.repo1, "ngwpc-candidate-pw")
    )
    record("PW environment uses -pw branches/tags", ok, f"exit={proc.returncode}")


# ---------------------------------------------------------------------------
# OFFICIAL workflow
# ---------------------------------------------------------------------------

def test_official_lifecycle(h: Harness):
    base = h.base_release("g")
    entries = [{"repo_directory": h.repo1, "release": base,
                "release_notes": "regression test release"}]

    # OFFICIAL requires ngwpc-candidate to exist with something to merge —
    # get there via one RC first.
    h.run_release("RC", entries)

    proc, _ = h.run_release("OFFICIAL", entries)
    project_name = os.path.basename(git(h.repo1, "remote", "get-url", "origin").stdout.strip()).replace(".git", "")
    clog = changelog_path(h.run_cwd, project_name, base)
    ok = (
        proc.returncode == 0
        and remote_tag_exists(h.repo1, base)
        and remote_branch_exists(h.repo1, "ngwpc-release")
        and os.path.isfile(clog)
        and branch_merged_into(h.repo1, "ngwpc-release", "development")
    )
    record("OFFICIAL: tags, changelog, release, merge-back", ok,
           f"exit={proc.returncode}, changelog={clog}")


# ---------------------------------------------------------------------------
# OWP workflow
# ---------------------------------------------------------------------------

def test_owp_branch_only(h: Harness):
    base = h.base_release("h")
    entries = [{"repo_directory": h.repo1, "release": base}]
    # OWP branches from ngwpc-release, so get a release branch in place first.
    h.run_release("RC", entries)
    h.run_release("OFFICIAL", entries)

    proc, _ = h.run_release("OWP", entries)
    ok = (
        proc.returncode == 0
        and remote_branch_exists(h.repo1, f"ngwpc-{base}")
        and not remote_tag_exists(h.repo1, f"ngwpc-{base}")  # no tag should be created
    )
    record("OWP creates branch only, no tag/release/PR", ok, f"exit={proc.returncode}")


# ---------------------------------------------------------------------------
# Submodules
# ---------------------------------------------------------------------------

def test_submodule_pointer_update(h: Harness):
    required = ["development", "ngwpc-candidate"]
    missing = [b for b in missing_submodule_branches(h.sub1) if b in required]
    if missing:
        record("has_submodules=true updates pointers on RC", False,
               f"peter_test_sub1 is missing branch(es) {missing} — "
               "create them (e.g. run createRelease.sh standalone against it) "
               "before this scenario can exercise the real commit path")
        return

    sub_path = submodule_paths(h.repo2)[0]
    base = h.base_release("i")
    entries = [{"repo_directory": h.repo2, "release": base, "has_submodules": True}]

    # createRelease.sh's default is now manual (it pauses instead of
    # touching pointers) — these scenarios need the automatic path to
    # actually verify anything, so --automatic-submodules is required here.
    automatic = ["--automatic-submodules"]

    # A distinct commit per branch, so a pointer landing on the wrong
    # branch's SHA gets caught instead of masked by reusing one commit
    # everywhere.
    candidate_sha = h.make_submodule_commit("ngwpc-candidate")
    proc1, _ = h.run_release("RC", entries, extra_args=automatic)
    rc1_ok = (
        proc1.returncode == 0
        and remote_tag_exists(h.repo2, f"{base}-rc1")
        and "Submodule pointer changes:" in proc1.stdout
        and submodule_gitlink_sha(h.repo2, "ngwpc-candidate", sub_path) == candidate_sha
    )
    record("RC1 picks up new submodule commit on ngwpc-candidate", rc1_ok,
           f"exit={proc1.returncode}")

    # RC1 never merges back to development — only RC2+ does — so the
    # development pointer only gets exercised on a second RC.
    development_sha = h.make_submodule_commit("development")
    proc2, _ = h.run_release("RC", entries, extra_args=automatic)
    rc2_ok = (
        proc2.returncode == 0
        and submodule_gitlink_sha(h.repo2, "development", sub_path) == development_sha
    )
    record("RC2 merge-back picks up new submodule commit on development", rc2_ok,
           f"exit={proc2.returncode}")


def test_submodule_pointer_update_pw(h: Harness):
    required = ["development-pw", "ngwpc-candidate-pw"]
    missing = [b for b in missing_submodule_branches(h.sub1) if b in required]
    if missing:
        record("has_submodules=true updates pointers on RC (PW)", False,
               f"peter_test_sub1 is missing branch(es) {missing} — create them first")
        return

    sub_path = submodule_paths(h.repo2)[0]
    base = h.base_release("i2")
    entries = [{"repo_directory": h.repo2, "release": base, "has_submodules": True}]
    automatic = ["--automatic-submodules"]

    candidate_sha = h.make_submodule_commit("ngwpc-candidate-pw")
    proc1, _ = h.run_release("RC", entries, environment="PW", extra_args=automatic)
    rc1_ok = (
        proc1.returncode == 0
        and remote_tag_exists(h.repo2, f"{base}-rc1-pw")
        and "Submodule pointer changes:" in proc1.stdout
        and submodule_gitlink_sha(h.repo2, "ngwpc-candidate-pw", sub_path) == candidate_sha
    )
    record("RC1 (PW) picks up new submodule commit on ngwpc-candidate-pw", rc1_ok,
           f"exit={proc1.returncode}")

    development_sha = h.make_submodule_commit("development-pw")
    proc2, _ = h.run_release("RC", entries, environment="PW", extra_args=automatic)
    rc2_ok = (
        proc2.returncode == 0
        and submodule_gitlink_sha(h.repo2, "development-pw", sub_path) == development_sha
    )
    record("RC2 (PW) merge-back picks up new submodule commit on development-pw", rc2_ok,
           f"exit={proc2.returncode}")


def test_submodule_pointer_update_official(h: Harness):
    required = ["development", "ngwpc-candidate", "ngwpc-release"]
    missing = [b for b in missing_submodule_branches(h.sub1) if b in required]
    if missing:
        record("has_submodules=true updates pointers on OFFICIAL", False,
               f"peter_test_sub1 is missing branch(es) {missing} — create them first")
        return

    sub_path = submodule_paths(h.repo2)[0]
    base = h.base_release("i3")
    entries = [{"repo_directory": h.repo2, "release": base, "has_submodules": True}]
    automatic = ["--automatic-submodules"]

    # OFFICIAL merges ngwpc-candidate -> ngwpc-release, so candidate needs
    # something in it first — a plain RC1 covers that.
    h.run_release("RC", entries, extra_args=automatic)

    # OFFICIAL merges back to development unconditionally (no RC1-style
    # skip), so a single run exercises both pointers.
    release_sha = h.make_submodule_commit("ngwpc-release")
    development_sha = h.make_submodule_commit("development")
    proc, _ = h.run_release("OFFICIAL", entries, extra_args=automatic)
    ok = (
        proc.returncode == 0
        and remote_tag_exists(h.repo2, base)
        and "Submodule pointer changes:" in proc.stdout
        and submodule_gitlink_sha(h.repo2, "ngwpc-release", sub_path) == release_sha
        and submodule_gitlink_sha(h.repo2, "development", sub_path) == development_sha
    )
    record("OFFICIAL picks up new submodule commits on ngwpc-release and merge-back to development",
           ok, f"exit={proc.returncode}")


def test_submodule_pointer_update_official_pw(h: Harness):
    required = ["development-pw", "ngwpc-candidate-pw", "ngwpc-release-pw"]
    missing = [b for b in missing_submodule_branches(h.sub1) if b in required]
    if missing:
        record("has_submodules=true updates pointers on OFFICIAL (PW)", False,
               f"peter_test_sub1 is missing branch(es) {missing} — create them first")
        return

    sub_path = submodule_paths(h.repo2)[0]
    base = h.base_release("i4")
    entries = [{"repo_directory": h.repo2, "release": base, "has_submodules": True}]
    automatic = ["--automatic-submodules"]

    h.run_release("RC", entries, environment="PW", extra_args=automatic)

    release_sha = h.make_submodule_commit("ngwpc-release-pw")
    development_sha = h.make_submodule_commit("development-pw")
    proc, _ = h.run_release("OFFICIAL", entries, environment="PW", extra_args=automatic)
    ok = (
        proc.returncode == 0
        and remote_tag_exists(h.repo2, f"{base}-pw")
        and "Submodule pointer changes:" in proc.stdout
        and submodule_gitlink_sha(h.repo2, "ngwpc-release-pw", sub_path) == release_sha
        and submodule_gitlink_sha(h.repo2, "development-pw", sub_path) == development_sha
    )
    record("OFFICIAL (PW) picks up new submodule commits on ngwpc-release-pw and merge-back to development-pw",
           ok, f"exit={proc.returncode}")


def test_submodule_manual_is_default(h: Harness):
    required = ["development", "ngwpc-candidate"]
    missing = [b for b in missing_submodule_branches(h.sub1) if b in required]
    if missing:
        record("manual submodule update is the default (no automatic pointer change)", False,
               f"peter_test_sub1 is missing branch(es) {missing} — create them first")
        return

    sub_path = submodule_paths(h.repo2)[0]
    base = h.base_release("i5")
    entries = [{"repo_directory": h.repo2, "release": base, "has_submodules": True}]

    # RC1 always merges from development regardless of automatic/manual
    # mode, so establish a known-good candidate pointer with
    # --automatic-submodules first — the real check is what RC2 (which never
    # merges from development again) does to that pointer with no flag at all.
    h.run_release("RC", entries, extra_args=["--automatic-submodules"])
    before = submodule_gitlink_sha(h.repo2, "ngwpc-candidate", sub_path)

    candidate_sha = h.make_submodule_commit("ngwpc-candidate")
    proc, _ = h.run_release("RC", entries)  # no --automatic-submodules
    after = submodule_gitlink_sha(h.repo2, "ngwpc-candidate", sub_path)

    ok = (
        proc.returncode == 0
        and "Manual submodule update" in proc.stdout
        and after == before
        and after != candidate_sha
    )
    record("manual submodule update is the default (no automatic pointer change)", ok,
           f"exit={proc.returncode}")


def test_submodule_noop_without_gitmodules(h: Harness):
    base = h.base_release("j")
    entries = [{"repo_directory": h.repo1, "release": base, "has_submodules": True}]
    proc, _ = h.run_release("RC", entries)
    ok = proc.returncode == 0 and "no .gitmodules file" in proc.stdout
    record("has_submodules=true with no .gitmodules is a no-op", ok)


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

SCENARIO_GROUPS = {
    "config": [test_help, test_missing_release_type, test_invalid_release_type,
               test_missing_config_file, test_malformed_json, test_non_array_json,
               test_bad_wait_time, test_bad_environment, test_bad_repo_env_field,
               test_missing_repo_directory, test_skip_flag, test_confirmation_abort,
               test_env_pw_skipped_under_standard, test_env_aws_skipped_under_pw,
               test_env_all_runs_under_both, test_env_absent_defaults_to_all],
    "rc": [test_rc_lifecycle, test_rc_duplicate_tag_rejected, test_rc_pw_environment],
    "official": [test_official_lifecycle],
    "owp": [test_owp_branch_only],
    "submodule": [test_submodule_pointer_update, test_submodule_pointer_update_pw,
                  test_submodule_pointer_update_official, test_submodule_pointer_update_official_pw,
                  test_submodule_manual_is_default, test_submodule_noop_without_gitmodules],
}

# Flat registry of every individual scenario, keyed by its function name with
# the "test_" prefix stripped (e.g. test_submodule_pointer_update ->
# "submodule_pointer_update"). Lets --test target one scenario directly
# instead of running its whole group.
ALL_TESTS = {}
for _group in SCENARIO_GROUPS.values():
    for _fn in _group:
        ALL_TESTS.setdefault(_fn.__name__.removeprefix("test_"), _fn)


def main():
    ap = argparse.ArgumentParser(
        description=(
            "Drives createRelease.sh against the real sandbox repos "
            "(peter_test1, peter_test2, peter_test_sub1) and asserts on the "
            "resulting git/gh state. No mocking of gh/git — this exercises "
            "the real merge/conflict/submodule logic against real GitHub repos."
        ),
        epilog=(
            "Examples:\n"
            "  # from a directory containing createRelease.sh, peter_test1,\n"
            "  # peter_test2, and peter_test_sub1 (all default to cwd-relative paths):\n"
            "  python3 regression_test.py\n\n"
            "  # override paths and/or run a subset of scenario groups:\n"
            "  python3 regression_test.py --script /path/to/createRelease.sh \\\n"
            "      --repo1 /path/to/peter_test1 --repo2 /path/to/peter_test2 \\\n"
            "      --sub1 /path/to/peter_test_sub1 --scenario rc,official\n\n"
            "  # run just one or two individual tests instead of a whole group:\n"
            "  python3 regression_test.py --test submodule_pointer_update\n"
            "  python3 regression_test.py --list-tests\n\n"
            "Requires: gh authenticated, git, jq all on PATH (same prereqs as "
            "createRelease.sh itself). Run reset_test_repos.sh first for a clean slate."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--script", default="createRelease.sh",
                     help="path to createRelease.sh (default: ./createRelease.sh)")
    ap.add_argument("--repo1", default="peter_test1",
                     help="path to peter_test1 (default: ./peter_test1)")
    ap.add_argument("--repo2", default="peter_test2",
                     help="path to peter_test2, has_submodules (default: ./peter_test2)")
    ap.add_argument("--sub1", default="peter_test_sub1",
                     help="path to peter_test_sub1 (default: ./peter_test_sub1)")
    ap.add_argument("--make-commit-script", default=None,
                     help="path to makeTestCommit.sh, used by the submodule pointer-update "
                          "scenarios to create a real distinguishing commit "
                          "(default: makeTestCommit.sh next to --script)")
    ap.add_argument("--run-cwd", default=None,
                     help="directory to invoke the script from (default: cwd)")
    ap.add_argument("--scenario", default="all",
                     help="comma-separated group names to run, or 'all' (default: all). "
                          "Groups: " + ",".join(SCENARIO_GROUPS))
    ap.add_argument("--test", default=None,
                     help="comma-separated individual test keys to run instead of a "
                          "whole --scenario group (e.g. --test submodule_pointer_update). "
                          "Use --list-tests to see all available keys.")
    ap.add_argument("--list-tests", action="store_true",
                     help="print all individual test keys, grouped, and exit")
    args = ap.parse_args()

    if args.list_tests:
        for g, fns in SCENARIO_GROUPS.items():
            print(f"{g}:")
            for fn in fns:
                print(f"  {fn.__name__.removeprefix('test_')}")
        sys.exit(0)

    run_cwd = os.path.abspath(args.run_cwd or os.getcwd())
    script = os.path.abspath(args.script)
    h = Harness(script, run_cwd,
                os.path.abspath(args.repo1),
                os.path.abspath(args.repo2),
                os.path.abspath(args.sub1),
                make_commit_script=(os.path.abspath(args.make_commit_script)
                                     if args.make_commit_script else None))

    global _log_root
    _log_root = run_cwd
    print(f"Per-check transcripts will be written under: {os.path.join(run_cwd, LOG_DIR_NAME)}\n")

    if args.test:
        keys = args.test.split(",")
        scenarios = []
        for key in keys:
            fn = ALL_TESTS.get(key)
            if fn is None:
                print(f"Unknown test: {key}", file=sys.stderr)
                print("Run --list-tests to see available keys.", file=sys.stderr)
                sys.exit(2)
            scenarios.append(fn)
        for scenario in scenarios:
            try:
                scenario(h)
            except Exception as exc:  # keep going so one failure doesn't kill the run
                record(scenario.__name__, False, f"raised: {exc}")
    else:
        groups = list(SCENARIO_GROUPS) if args.scenario == "all" else args.scenario.split(",")
        for g in groups:
            if g not in SCENARIO_GROUPS:
                print(f"Unknown group: {g}", file=sys.stderr)
                sys.exit(2)
            for scenario in SCENARIO_GROUPS[g]:
                try:
                    scenario(h)
                except Exception as exc:  # keep going so one failure doesn't kill the run
                    record(scenario.__name__, False, f"raised: {exc}")

    print("\n=== Summary ===")
    failed = [r for r in RESULTS if not r.passed]
    for r in RESULTS:
        line = f"  [{'PASS' if r.passed else 'FAIL'}] {r.name}"
        if r.log_path:
            line += f"  ({os.path.basename(r.log_path)})"
        print(line)
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
