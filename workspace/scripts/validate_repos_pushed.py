#!/usr/bin/env python3
"""Validates whether all Git repositories in a folder are clean and pushed to a remote.

Behavior:
1. Scans a target directory (defaults to `~/workspace`, or a specific subfolder such
   as `~/workspace/personal` via positional `folder` or `--folder`).
2. Recursively discovers Git repositories (deduplicating symlinks).
3. Optionally runs `git fetch --all --prune` (`--fetch`) before checking status.
4. Verifies that each repository:
   - Has at least one Git remote configured.
   - Has a clean working tree (no uncommitted modifications or untracked files,
     unless `--ignore-dirty` or `--ignore-untracked` is passed).
   - Has all local branch and HEAD commits pushed to a remote branch.
5. Exits with code 0 if all repositories are pushed (or in `--dry-run` mode), and
   code 1 if any repository has unpushed or uncommitted work.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
import subprocess
import sys

DEFAULT_WORKSPACE = Path.home() / "workspace"
SKIP_DIRS = {
    ".git",
    "node_modules",
    "__pycache__",
    ".venv",
    "venv",
    "dist",
    "build",
    "target",
}


@dataclass
class RepoValidationResult:
    path: Path
    branch: str = "unknown"
    pushed: bool = True
    error: str | None = None
    reasons: list[str] = field(default_factory=list)


def run_git(repo_path: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo_path), *args],
        check=False,
        capture_output=True,
        text=True,
    )


def resolve_target_folder(workspace: Path, folder: str | None) -> Path:
    if not folder:
        return workspace.expanduser().resolve()

    candidate = Path(folder).expanduser()
    if candidate.exists():
        return candidate.resolve()

    workspace_candidate = workspace.expanduser() / folder
    if workspace_candidate.exists():
        return workspace_candidate.resolve()

    return candidate.resolve()


def find_git_repos(root: Path) -> list[Path]:
    """Recursively finds git repositories under `root`, deduplicating symlink targets."""
    repos: list[Path] = []
    seen_real_paths: set[Path] = set()

    if not root.exists():
        return repos

    def _walk(current: Path) -> None:
        try:
            is_git = (current / ".git").exists()
        except OSError:
            return

        if is_git:
            real_path = current.resolve()
            if real_path not in seen_real_paths:
                seen_real_paths.add(real_path)
                repos.append(current)
            return

        try:
            children = sorted(current.iterdir())
        except OSError:
            return

        for child in children:
            if not child.is_dir():
                continue
            if child.name.startswith(".") or child.name in SKIP_DIRS:
                continue
            _walk(child)

    _walk(root)
    return repos


def validate_repo(
    repo_path: Path,
    fetch: bool = False,
    ignore_dirty: bool = False,
    ignore_untracked: bool = False,
) -> RepoValidationResult:
    result = RepoValidationResult(path=repo_path)

    if fetch:
        fetch_res = run_git(repo_path, ["fetch", "--all", "--prune", "--quiet"])
        if fetch_res.returncode != 0:
            result.pushed = False
            result.error = f"git fetch failed: {fetch_res.stderr.strip()}"
            return result

    # 1. Determine current branch / HEAD state.
    branch_res = run_git(repo_path, ["symbolic-ref", "--short", "-q", "HEAD"])
    head_exists = (
        run_git(repo_path, ["rev-parse", "--verify", "-q", "HEAD"]).returncode == 0
    )
    if branch_res.returncode == 0:
        result.branch = branch_res.stdout.strip()
    elif head_exists:
        result.branch = "HEAD (detached)"
    else:
        result.branch = "HEAD (unborn)"

    # 2. Check configured remotes.
    remote_res = run_git(repo_path, ["remote"])
    if remote_res.returncode != 0:
        result.pushed = False
        result.error = f"git remote failed: {remote_res.stderr.strip()}"
        return result

    remotes = [line.strip() for line in remote_res.stdout.splitlines() if line.strip()]
    if not remotes:
        result.reasons.append("no remote configured")

    # 3. Check working tree cleanliness (staged, unstaged, untracked).
    if not ignore_dirty:
        status_res = run_git(repo_path, ["status", "--porcelain"])
        if status_res.returncode != 0:
            result.pushed = False
            result.error = f"git status failed: {status_res.stderr.strip()}"
            return result

        modified_count = 0
        untracked_count = 0
        for line in status_res.stdout.splitlines():
            if not line:
                continue
            if line.startswith("??"):
                untracked_count += 1
            else:
                modified_count += 1

        if modified_count > 0:
            result.reasons.append(f"{modified_count} uncommitted change(s)")
        if untracked_count > 0 and not ignore_untracked:
            result.reasons.append(f"{untracked_count} untracked file(s)")

    # 4. Check commits and local branches against remotes.
    if head_exists and remotes:
        refs_res = run_git(
            repo_path,
            [
                "for-each-ref",
                "--format=%(refname:short)|%(upstream:short)|%(upstream:track)",
                "refs/heads/",
            ],
        )
        for line in refs_res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split("|", 2)
            branch_name = parts[0].strip()
            upstream = parts[1].strip() if len(parts) > 1 else ""
            track = parts[2].strip() if len(parts) > 2 else ""

            if upstream:
                if "ahead" in track:
                    track_info = track.strip("[]")
                    result.reasons.append(
                        f"branch '{branch_name}' is {track_info} of '{upstream}'"
                    )
                elif track == "[gone]":
                    result.reasons.append(
                        f"branch '{branch_name}' upstream '{upstream}' is gone"
                    )
            else:
                unpushed_res = run_git(
                    repo_path,
                    ["rev-list", "--count", branch_name, "--not", "--remotes"],
                )
                unpushed_count = (
                    int(unpushed_res.stdout.strip())
                    if unpushed_res.returncode == 0
                    and unpushed_res.stdout.strip().isdigit()
                    else 0
                )
                if unpushed_count > 0:
                    result.reasons.append(
                        f"branch '{branch_name}' has {unpushed_count} unpushed commit(s) (no upstream)"
                    )
                else:
                    contains_res = run_git(
                        repo_path, ["branch", "-r", "--contains", branch_name]
                    )
                    if not contains_res.stdout.strip():
                        result.reasons.append(
                            f"branch '{branch_name}' is not pushed to any remote"
                        )

        if result.branch == "HEAD (detached)":
            detached_res = run_git(
                repo_path, ["rev-list", "--count", "HEAD", "--not", "--remotes"]
            )
            detached_unpushed = (
                int(detached_res.stdout.strip())
                if detached_res.returncode == 0
                and detached_res.stdout.strip().isdigit()
                else 0
            )
            if detached_unpushed > 0:
                result.reasons.append(
                    f"detached HEAD has {detached_unpushed} unpushed commit(s)"
                )

    result.pushed = len(result.reasons) == 0 and result.error is None
    return result


def format_display_path(repo_path: Path, target_root: Path) -> str:
    try:
        rel = repo_path.relative_to(target_root)
        return str(rel) if str(rel) != "." else repo_path.name
    except ValueError:
        return str(repo_path)


def validate_folder_repos(
    target_root: Path,
    fetch: bool = False,
    ignore_dirty: bool = False,
    ignore_untracked: bool = False,
    jobs: int = 4,
    verbose: bool = False,
    dry_run: bool = False,
) -> int:
    if not target_root.exists():
        if dry_run:
            print(
                f"[dry-run] Target folder {target_root} does not exist; 0 repositories to validate."
            )
            return 0
        print(f"[error] Target folder not found: {target_root}", file=sys.stderr)
        return 1

    repos = find_git_repos(target_root)
    if not repos:
        if dry_run:
            print(f"[dry-run] No git repositories found under {target_root}.")
            return 0
        print(f"[warn] No git repositories found under {target_root}.")
        return 0

    if dry_run:
        action = "fetch and validate" if fetch else "validate"
        print(
            f"[dry-run] Would {action} {len(repos)} git repository(ies) in {target_root}"
        )
        if verbose:
            for repo in repos:
                print(
                    f"[dry-run] Would {action} {format_display_path(repo, target_root)}"
                )
        print(
            f"\nSummary: total={len(repos)}, pushed=0, unpushed=0, errors=0, dry_run=True"
        )
        return 0

    results_by_path: dict[Path, RepoValidationResult] = {}
    if jobs <= 1 or len(repos) == 1:
        for repo in repos:
            results_by_path[repo] = validate_repo(
                repo,
                fetch=fetch,
                ignore_dirty=ignore_dirty,
                ignore_untracked=ignore_untracked,
            )
    else:
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = {
                executor.submit(
                    validate_repo,
                    repo,
                    fetch,
                    ignore_dirty,
                    ignore_untracked,
                ): repo
                for repo in repos
            }
            for future in as_completed(futures):
                repo = futures[future]
                results_by_path[repo] = future.result()

    pushed_count = 0
    unpushed_count = 0
    error_count = 0

    for repo in repos:
        res = results_by_path[repo]
        display = format_display_path(repo, target_root)
        if res.error:
            error_count += 1
            print(f"[error] {display} ({res.branch}): {res.error}", file=sys.stderr)
        elif res.pushed:
            pushed_count += 1
            if verbose:
                print(f"[ok] {display} ({res.branch})")
        else:
            unpushed_count += 1
            reasons_str = "; ".join(res.reasons)
            print(f"[unpushed] {display} ({res.branch}): {reasons_str}")

    if unpushed_count == 0 and error_count == 0 and not verbose:
        print(
            f"[ok] All {len(repos)} repository(ies) in {target_root} are clean and pushed."
        )

    print(
        f"\nSummary: total={len(repos)}, pushed={pushed_count}, "
        f"unpushed={unpushed_count}, errors={error_count}"
    )
    return 0 if (unpushed_count == 0 and error_count == 0) else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate whether all git repositories in a folder are clean and pushed."
    )
    parser.add_argument(
        "folder",
        nargs="?",
        default=None,
        help="Optional target folder path or category name under ~/workspace (e.g., 'personal').",
    )
    parser.add_argument(
        "-f",
        "--folder",
        dest="folder_flag",
        type=str,
        default=None,
        help="Target folder path or category name under ~/workspace (e.g., 'personal').",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=DEFAULT_WORKSPACE,
        help=f"Base workspace directory (default: {DEFAULT_WORKSPACE}).",
    )
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="Run 'git fetch --all --prune' on each repository before validating.",
    )
    parser.add_argument(
        "--ignore-dirty",
        action="store_true",
        help="Ignore uncommitted working-tree changes and only validate unpushed commits.",
    )
    parser.add_argument(
        "--ignore-untracked",
        action="store_true",
        help="Ignore untracked files when checking working-tree cleanliness.",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=4,
        help="Number of concurrent workers (default: 4).",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Also print [ok] lines for clean and pushed repositories.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview repositories that would be validated without making network calls or failing.",
    )
    args = parser.parse_args()

    selected_folder = args.folder_flag or args.folder
    target_root = resolve_target_folder(args.workspace, selected_folder)

    sys.exit(
        validate_folder_repos(
            target_root=target_root,
            fetch=args.fetch,
            ignore_dirty=args.ignore_dirty,
            ignore_untracked=args.ignore_untracked,
            jobs=args.jobs,
            verbose=args.verbose,
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
