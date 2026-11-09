#!/usr/bin/env python3
"""Organizes and clones repositories listed in documentation/repo_stats.csv into ~/workspace.

Behavior:
1. Reads `documentation/repo_stats.csv`.
2. Ignores any row where `folder` is empty, as well as any local folder/repo in
   `~/workspace` that is not described with a target `folder` in the CSV.
3. Scans `~/workspace` for already-cloned repositories and moves them to
   `~/workspace/<folder>/<name>` if they are currently in a different folder.
4. Clones any remaining repositories that have a `folder` assigned in the CSV
   into `~/workspace/<folder>/<name>`.

SSH keys with a passphrase are supported: before cloning, SSH access is checked
non-interactively. If it fails, an existing ssh-agent is reused (or a temporary
one is started) and `ssh-add` prompts for the passphrase once, so parallel
clones never prompt on the terminal. Keys without a passphrase skip this step.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CSV_PATH = REPO_ROOT / "documentation" / "repo_stats.csv"
DEFAULT_WORKSPACE = Path.home() / "workspace"


def load_csv_repos(csv_path: Path) -> dict[str, dict[str, str]]:
    if not csv_path.exists():
        sys.exit(f"CSV file not found: {csv_path}")

    repos: dict[str, dict[str, str]] = {}
    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            name = (row.get("name") or "").strip()
            folder = (row.get("folder") or "").strip()
            # Only manage repos that have both a name and a target folder in the CSV.
            if not name or not folder:
                continue
            repos[name] = {
                "name": name,
                "folder": folder,
                "link": (row.get("link") or "").strip(),
                "ssh_link": (row.get("ssh link") or "").strip(),
            }
    return repos


def find_existing_cloned_repos(
    workspace: Path,
) -> tuple[dict[str, list[Path]], dict[str, list[Path]]]:
    """Finds real git repositories and any repo symlinks under ~/workspace (up to 2 levels deep)."""
    found: dict[str, list[Path]] = {}
    symlinks: dict[str, list[Path]] = {}
    if not workspace.exists():
        return found, symlinks

    for child in sorted(workspace.iterdir()):
        if child.name.startswith("."):
            continue
        if child.is_symlink():
            symlinks.setdefault(child.name, []).append(child)
            continue
        if not child.is_dir():
            continue

        # Direct repo at ~/workspace/<repo>
        if (child / ".git").exists():
            found.setdefault(child.name, []).append(child)
            continue

        # Category folder at ~/workspace/<folder>/<repo>
        for grandchild in sorted(child.iterdir()):
            if grandchild.name.startswith("."):
                continue
            if grandchild.is_symlink():
                symlinks.setdefault(grandchild.name, []).append(grandchild)
                continue
            if not grandchild.is_dir():
                continue
            if (grandchild / ".git").exists():
                found.setdefault(grandchild.name, []).append(grandchild)

    return found, symlinks


# Never prompt from inside (parallel) clones: SSH fails fast instead of asking for a
# passphrase, and HTTPS fallbacks fail instead of asking for credentials.
CLONE_ENV_OVERRIDES = {
    "GIT_SSH_COMMAND": os.environ.get("GIT_SSH_COMMAND", "ssh -o BatchMode=yes"),
    "GIT_TERMINAL_PROMPT": "0",
}


def ssh_host_from_url(url: str) -> str | None:
    """Extracts `user@host` from `git@host:owner/repo.git` or `ssh://git@host/...` URLs."""
    match = re.match(r"^(?:ssh://)?([^@/\s]+@[^:/\s]+)[:/]", url)
    return match.group(1) if match else None


def ssh_auth_works(host: str) -> bool:
    """Checks SSH authentication without ever prompting (GitHub exits 1 even on success)."""
    result = subprocess.run(
        [
            "ssh", "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            host,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    output = f"{result.stdout}\n{result.stderr}".lower()
    return result.returncode == 0 or "successfully authenticated" in output


def agent_reachable() -> bool:
    # `ssh-add -l` exits 0 (has keys), 1 (no keys) or 2 (no agent reachable).
    if not os.environ.get("SSH_AUTH_SOCK"):
        return False
    result = subprocess.run(["ssh-add", "-l"], check=False, capture_output=True)
    return result.returncode in (0, 1)


def start_ssh_agent() -> str | None:
    """Starts a temporary ssh-agent, exports its env into os.environ and returns its PID."""
    result = subprocess.run(
        ["ssh-agent", "-s"], check=False, capture_output=True, text=True
    )
    if result.returncode != 0:
        return None
    for key, value in re.findall(r"(SSH_AUTH_SOCK|SSH_AGENT_PID)=([^;]+);", result.stdout):
        os.environ[key] = value
    return os.environ.get("SSH_AGENT_PID")


def ensure_ssh_auth(host: str, ssh_key: Path | None) -> str | None:
    """Makes SSH auth to `host` work non-interactively.

    Returns the PID of a temporary ssh-agent started by this script (to be killed
    afterwards), or None if no agent was started.
    """
    if ssh_auth_works(host):
        print(f"[ssh] Non-interactive SSH access to {host} OK.")
        return None

    started_pid = None
    if not agent_reachable():
        started_pid = start_ssh_agent()
        if not started_pid:
            print("[warn] Could not start ssh-agent; SSH clones may fall back to HTTPS.")
            return None
        print(f"[ssh] Started temporary ssh-agent (pid {started_pid}).")

    print(f"[ssh] SSH key needs to be unlocked for {host}; running ssh-add ...")
    add_cmd = ["ssh-add"] + ([str(ssh_key.expanduser())] if ssh_key else [])
    subprocess.run(add_cmd, check=False)  # Interactive: prompts for the passphrase once.

    if ssh_auth_works(host):
        print(f"[ssh] SSH access to {host} OK via ssh-agent.")
    else:
        print(f"[warn] SSH access to {host} still failing; clones will fall back to HTTPS.")
    return started_pid


def stop_ssh_agent(pid: str) -> None:
    subprocess.run(["ssh-agent", "-k"], check=False, capture_output=True)
    print(f"[ssh] Stopped temporary ssh-agent (pid {pid}).")


def clone_repo(repo: dict[str, str], target_path: Path, dry_run: bool = False) -> bool:
    clone_url = repo["ssh_link"] or repo["link"]
    if not clone_url:
        print(f"[skip] {repo['name']}: no clone URL in CSV", file=sys.stderr)
        return False

    if dry_run:
        print(f"[dry-run] Would clone {clone_url} -> {target_path}")
        return True

    target_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"[clone] Cloning {clone_url} -> {target_path} ...")
    result = subprocess.run(
        ["git", "clone", clone_url, str(target_path)],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, **CLONE_ENV_OVERRIDES},
    )
    if result.returncode == 0:
        return True

    # Fallback to HTTPS link if SSH clone failed and HTTPS link is available.
    if repo["ssh_link"] and repo["link"] and clone_url != repo["link"]:
        print(
            f"[warn] SSH clone failed for {repo['name']}, retrying with HTTPS ({repo['link']})..."
        )
        result_https = subprocess.run(
            ["git", "clone", repo["link"], str(target_path)],
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, **CLONE_ENV_OVERRIDES},
        )
        if result_https.returncode == 0:
            return True
        print(
            f"[error] Failed to clone {repo['name']}: {result_https.stderr.strip()}",
            file=sys.stderr,
        )
        return False

    print(
        f"[error] Failed to clone {repo['name']}: {result.stderr.strip()}",
        file=sys.stderr,
    )
    return False


def sync_workspace(
    csv_path: Path,
    workspace: Path,
    dry_run: bool = False,
    jobs: int = 4,
    ssh_key: Path | None = None,
) -> None:
    managed_repos = load_csv_repos(csv_path)
    workspace.mkdir(parents=True, exist_ok=True)

    existing_repos, repo_symlinks = find_existing_cloned_repos(workspace)

    already_in_place = 0
    moved_count = 0
    cloned_count = 0
    failed_count = 0

    # Clean up any symlinks for managed repositories so moves/clones use real directories only.
    for name in managed_repos:
        for link_path in repo_symlinks.get(name, []):
            if dry_run:
                print(f"[dry-run] Would remove symlink {link_path}")
            else:
                link_path.unlink(missing_ok=True)
                print(f"[unlink] Removed symlink {link_path}")

    # Step 1: Organize already-cloned repos that are described in the CSV (move directly, never symlink).
    for name, repo in managed_repos.items():
        target_dir = workspace / repo["folder"] / name
        locations = existing_repos.get(name, [])

        if not locations:
            continue

        if target_dir in locations:
            already_in_place += 1
            continue

        source_dir = locations[0]
        if target_dir.is_symlink():
            if dry_run:
                print(f"[dry-run] Would remove symlink {target_dir}")
            else:
                target_dir.unlink(missing_ok=True)
        elif target_dir.exists():
            print(
                f"[skip] Target {target_dir} already exists; leaving {source_dir} as is."
            )
            continue

        if dry_run:
            print(f"[dry-run] Would move {source_dir} -> {target_dir}")
            moved_count += 1
        else:
            target_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source_dir), str(target_dir))
            print(f"[move] Moved {source_dir} -> {target_dir}")
            moved_count += 1

    # Refresh existing locations after moves.
    if not dry_run:
        existing_repos, _ = find_existing_cloned_repos(workspace)

    # Step 2: Clone missing repos that have a target folder in the CSV.
    to_clone: list[tuple[dict[str, str], Path]] = []
    for name, repo in managed_repos.items():
        target_dir = workspace / repo["folder"] / name
        if target_dir.exists():
            continue
        if dry_run and name in existing_repos:
            continue
        to_clone.append((repo, target_dir))

    # Unlock SSH once up front so clones never prompt for a passphrase.
    agent_pid = None
    ssh_hosts = sorted(
        {h for repo, _ in to_clone if (h := ssh_host_from_url(repo["ssh_link"]))}
    )
    if to_clone and not dry_run:
        for host in ssh_hosts:
            agent_pid = ensure_ssh_auth(host, ssh_key) or agent_pid

    try:
        if dry_run or jobs <= 1:
            for repo, target_dir in to_clone:
                if clone_repo(repo, target_dir, dry_run=dry_run):
                    cloned_count += 1
                else:
                    failed_count += 1
        elif to_clone:
            with ThreadPoolExecutor(max_workers=jobs) as executor:
                futures = {
                    executor.submit(clone_repo, repo, target_dir, False): repo["name"]
                    for repo, target_dir in to_clone
                }
                for future in as_completed(futures):
                    if future.result():
                        cloned_count += 1
                    else:
                        failed_count += 1
    finally:
        if agent_pid:
            stop_ssh_agent(agent_pid)

    print(
        f"\nSummary: configured_in_csv={len(managed_repos)}, "
        f"already_in_place={already_in_place}, moved={moved_count}, "
        f"cloned={cloned_count}, failed={failed_count}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Organize and clone repositories in ~/workspace based on documentation/repo_stats.csv."
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=DEFAULT_CSV_PATH,
        help=f"Path to repo_stats.csv (default: {DEFAULT_CSV_PATH})",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=DEFAULT_WORKSPACE,
        help=f"Path to workspace directory (default: {DEFAULT_WORKSPACE})",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=4,
        help="Number of concurrent git clone operations (default: 4).",
    )
    parser.add_argument(
        "--ssh-key",
        type=Path,
        default=None,
        help="SSH private key to unlock with ssh-add if needed (default: ssh-add's default keys).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview moves and clones without making changes.",
    )
    args = parser.parse_args()
    sync_workspace(
        args.csv.resolve(),
        args.workspace.expanduser().resolve(),
        dry_run=args.dry_run,
        jobs=args.jobs,
        ssh_key=args.ssh_key,
    )


if __name__ == "__main__":
    main()
