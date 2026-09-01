#!/usr/bin/env python3
"""
Generate candidate release commit summaries from createReleaseConfig.json.

This script processes repositories in the config where "skip" is false and writes
commits after a user-provided date to a text file.

Behavior intentionally mirrors the findMerges.sh candidate-release workflow:
- uses origin/development by default
- includes merge commits by default
- filters commits with git log --after=<date>
- processes only repositories where skip is false

Example:
    python genCandidateCommitList.py -a 2026-03-12 -o candidateReleaseCommits.txt

Example with explicit target ref:
    python genCandidateCommitList.py -a 2026-03-12 -t origin/development -o candidateReleaseCommits.txt
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = "createReleaseConfig.json"
DEFAULT_TARGET_REF = "origin/development"


@dataclass
class RepoConfig:
    repo_directory: str
    upstream_repo: str
    release: str
    previous_release_tag: str
    release_notes: str
    commit_summary: str
    skip: bool


def run_git(repo_dir: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=repo_dir,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def repo_name(repo_dir: Path) -> str:
    return repo_dir.name


def expand_repo_dir(path: str) -> Path:
    return Path(os.path.expanduser(path)).resolve()


def load_config(config_file: Path) -> list[RepoConfig]:
    """
    Load createReleaseConfig.json.

    The config may contain extra fields such as "has_submodules".
    Those are intentionally ignored here.
    """
    with config_file.open("r", encoding="utf-8") as f:
        raw_repos: list[dict[str, Any]] = json.load(f)

    repos: list[RepoConfig] = []

    for raw in raw_repos:
        repos.append(
            RepoConfig(
                repo_directory=raw.get("repo_directory", ""),
                upstream_repo=raw.get("upstream_repo", ""),
                release=raw.get("release", ""),
                previous_release_tag=raw.get("previous_release_tag", ""),
                release_notes=raw.get("release_notes", ""),
                commit_summary=raw.get("commit_summary", ""),
                skip=bool(raw.get("skip", False)),
            )
        )

    return repos


def ensure_git_repo(repo_dir: Path) -> tuple[bool, str]:
    if not repo_dir.exists():
        return False, "repository directory does not exist"

    if not (repo_dir / ".git").exists():
        return False, "directory is not a git repository"

    return True, ""


def ref_exists(repo_dir: Path, ref: str) -> bool:
    result = run_git(repo_dir, ["rev-parse", "--verify", "--quiet", ref])
    return result.returncode == 0


def get_current_branch(repo_dir: Path) -> str:
    result = run_git(repo_dir, ["branch", "--show-current"])
    branch = result.stdout.strip()
    return branch if branch else "detached HEAD"


def get_target_description(repo_dir: Path, target_ref: str) -> str:
    result = run_git(repo_dir, ["rev-parse", "--short", target_ref])
    if result.returncode == 0:
        return f"{target_ref} ({result.stdout.strip()})"
    return target_ref


def fetch_development(repo_dir: Path) -> str:
    result = run_git(repo_dir, ["fetch", "origin", "development"])
    if result.returncode != 0:
        return result.stderr.strip() or "git fetch origin development failed"
    return ""


def get_commits_after_date(
    repo_dir: Path,
    after_date: str,
    target_ref: str,
) -> tuple[list[str], str]:
    """
    Return commit lines and an optional warning.

    Commit format:
      <short-hash> | <date> | <author> | <subject>

    Merge commits are included by default to match findMerges.sh --mode any.
    """
    if not ref_exists(repo_dir, target_ref):
        return [], f"target ref '{target_ref}' was not found"

    result = run_git(
        repo_dir,
        [
            "log",
            target_ref,
            f"--after={after_date}",
            "--date=short",
            "--pretty=format:%h | %ad | %an | %s",
        ],
    )

    if result.returncode != 0:
        return [], result.stderr.strip() or "git log failed"

    commits = [line for line in result.stdout.splitlines() if line.strip()]
    return commits, ""


def append_repository_name_summary(
    lines: list[str],
    title: str,
    repo_names: list[str],
) -> None:
    lines.append(title)
    lines.append("-" * len(title))

    if repo_names:
        for name in sorted(repo_names, key=str.lower):
            lines.append(f"  - {name}")
    else:
        lines.append("  - None")

    lines.append("")


def write_repo_section(
    lines: list[str],
    repo: RepoConfig,
    repo_dir: Path,
    target_ref: str,
    after_date: str,
    commits: list[str],
    warning: str,
) -> None:
    title = repo_name(repo_dir)

    lines.append("=" * 88)
    lines.append(f"Repository: {title}")
    lines.append("=" * 88)
    lines.append(f"Upstream Repo         : {repo.upstream_repo or 'N/A'}")
    lines.append(f"Local Directory       : {repo_dir}")
    lines.append(f"Current Branch        : {get_current_branch(repo_dir)}")
    lines.append(f"Candidate Release Tag : {repo.release or 'N/A'}")
    lines.append(f"Previous Release Tag  : {repo.previous_release_tag or 'N/A'}")
    lines.append(f"Target Ref Used       : {get_target_description(repo_dir, target_ref)}")
    lines.append(f"Commits After         : {after_date}")
    lines.append(f"Configured Notes      : {repo.release_notes or 'N/A'}")
    lines.append(f"Configured Summary    : {repo.commit_summary or 'N/A'}")

    if warning:
        lines.append(f"WARNING               : {warning}")

    lines.append("")
    lines.append(f"Commit Count          : {len(commits)}")
    lines.append("")
    lines.append("Commits:")

    if commits:
        for commit in commits:
            lines.append(f"  - {commit}")
    else:
        lines.append("  - No commits found.")

    lines.append("")


def write_skipped_repo_section(
    lines: list[str],
    repo: RepoConfig,
    repo_dir: Path,
    reason: str,
    after_date: str,
) -> None:
    title = repo_name(repo_dir)

    lines.append("=" * 88)
    lines.append(f"Repository: {title}")
    lines.append("=" * 88)
    lines.append(f"Upstream Repo         : {repo.upstream_repo or 'N/A'}")
    lines.append(f"Local Directory       : {repo_dir}")
    lines.append(f"Candidate Release Tag : {repo.release or 'N/A'}")
    lines.append(f"Previous Release Tag  : {repo.previous_release_tag or 'N/A'}")
    lines.append(f"Commits After         : {after_date}")
    lines.append(f"WARNING               : Skipped because {reason}.")
    lines.append("")
    lines.append("Commits:")
    lines.append("  - No commits found.")
    lines.append("")


def build_header(
    config_file: Path,
    after_date: str,
    target_ref: str,
    repos_in_config_count: int,
    selected_repos_count: int,
    repos_with_commits_count: int,
    repos_without_commits_count: int,
    repos_with_warnings_count: int,
    missing_or_invalid_repos_count: int,
) -> list[str]:
    lines: list[str] = []

    lines.append("Candidate Release Commit List")
    lines.append(f"Generated                 : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Config File               : {config_file}")
    lines.append(f"Commits After             : {after_date}")
    lines.append(f"Target Ref                : {target_ref}")
    lines.append(f"Repositories in Config    : {repos_in_config_count}")
    lines.append(f"Repositories Processed    : {selected_repos_count}")
    lines.append(f"Repositories w/Commits    : {repos_with_commits_count}")
    lines.append(f"Repositories w/o Commits  : {repos_without_commits_count}")
    lines.append(f"Repositories w/Warnings   : {repos_with_warnings_count}")
    lines.append(f"Missing/Invalid Repos     : {missing_or_invalid_repos_count}")
    lines.append(f"Merge Commits             : included")
    lines.append("")
    lines.append("INSTRUCTIONS:")
    lines.append(
        "Descriptively summarize commits per repository into a concise paragraph."
        "Group related changes when appropriate. Avoid listing every commit unless "
        "necessary. Focus on meaningful functional, operational, build, dependency, "
        "or user-facing changes. Avoid terms like general fixes and improvements."
        "Provide a short title for each repository suitable"
        "Avoid titles that simply state the rrepository name follwed by the word Improvements, Updates or Enhancements."
        "for creating a release in GitHub. Provide this in a downloadable markdown file."
    )
    lines.append("")
    lines.append("=" * 88)
    lines.append("")

    return lines


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a text file listing commits after a specified date for each "
            "repository in createReleaseConfig.json where skip is false."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    parser.add_argument(
        "-a",
        "--after",
        required=True,
        help=(
            "Only include commits after this date/time. Examples: "
            "'2026-03-12', '2026-03-12 15:30:00', "
            "'2026-03-12 15:30:00 -0500'."
        ),
    )

    parser.add_argument(
        "-c",
        "--config",
        default=DEFAULT_CONFIG,
        help="Path to createReleaseConfig.json",
    )

    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Required output text file",
    )

    parser.add_argument(
        "-t",
        "--target-ref",
        default=DEFAULT_TARGET_REF,
        help=(
            "Git ref to inspect. Defaults to origin/development to match the "
            "candidate release workflow."
        ),
    )

    parser.add_argument(
        "--no-fetch",
        action="store_true",
        help="Do not run 'git fetch origin development' before collecting commits.",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    config_file = Path(args.config).expanduser().resolve()
    output_file = Path(args.output).expanduser().resolve()

    if not config_file.exists():
        print(f"ERROR: Config file not found: {config_file}", file=sys.stderr)
        return 2

    repos = load_config(config_file)
    selected_repos = [repo for repo in repos if not repo.skip]

    body_lines: list[str] = []

    repos_with_commits: list[str] = []
    repos_without_commits: list[str] = []
    repos_with_warnings: list[str] = []
    missing_or_invalid_repos: list[str] = []

    for repo in selected_repos:
        repo_dir = expand_repo_dir(repo.repo_directory)
        title = repo_name(repo_dir)

        print(f"Processing {title}...")

        ok, reason = ensure_git_repo(repo_dir)
        if not ok:
            missing_or_invalid_repos.append(title)
            repos_without_commits.append(title)
            repos_with_warnings.append(title)
            write_skipped_repo_section(body_lines, repo, repo_dir, reason, args.after)
            continue

        warning = ""

        if not args.no_fetch:
            fetch_warning = fetch_development(repo_dir)
            if fetch_warning:
                warning = fetch_warning

        commits, log_warning = get_commits_after_date(
            repo_dir=repo_dir,
            after_date=args.after,
            target_ref=args.target_ref,
        )

        if log_warning:
            warning = f"{warning}; {log_warning}" if warning else log_warning

        if commits:
            repos_with_commits.append(title)
        else:
            repos_without_commits.append(title)

        if warning:
            repos_with_warnings.append(title)

        write_repo_section(
            lines=body_lines,
            repo=repo,
            repo_dir=repo_dir,
            target_ref=args.target_ref,
            after_date=args.after,
            commits=commits,
            warning=warning,
        )

    header_lines = build_header(
        config_file=config_file,
        after_date=args.after,
        target_ref=args.target_ref,
        repos_in_config_count=len(repos),
        selected_repos_count=len(selected_repos),
        repos_with_commits_count=len(repos_with_commits),
        repos_without_commits_count=len(repos_without_commits),
        repos_with_warnings_count=len(repos_with_warnings),
        missing_or_invalid_repos_count=len(missing_or_invalid_repos),
    )

    summary_lines: list[str] = []
    append_repository_name_summary(summary_lines, "Repositories With Commits", repos_with_commits)
    append_repository_name_summary(summary_lines, "Repositories Without Commits", repos_without_commits)
    append_repository_name_summary(summary_lines, "Repositories With Warnings", repos_with_warnings)
    append_repository_name_summary(summary_lines, "Missing or Invalid Repositories", missing_or_invalid_repos)
    summary_lines.append("=" * 88)
    summary_lines.append("")

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(
        "\n".join(header_lines + summary_lines + body_lines) + "\n",
        encoding="utf-8",
    )

    print(f"Done. Wrote commit list to: {output_file}")
    print(f"Repositories processed      : {len(selected_repos)}")
    print(f"Repositories w/commits      : {len(repos_with_commits)}")
    print(f"Repositories w/o commits    : {len(repos_without_commits)}")
    print(f"Repositories w/warnings     : {len(repos_with_warnings)}")
    print(f"Missing/invalid repositories: {len(missing_or_invalid_repos)}")

    if repos_without_commits:
        print("\nRepositories WITHOUT commits:")
        for repo_name_item in sorted(repos_without_commits, key=str.lower):
            print(f"  - {repo_name_item}")

    if repos_with_warnings:
        print("\nRepositories WITH warnings:")
        for repo_name_item in sorted(repos_with_warnings, key=str.lower):
            print(f"  - {repo_name_item}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
