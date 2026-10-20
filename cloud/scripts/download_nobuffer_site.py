#!/usr/bin/env python3
"""Downloads or updates the nobuffer-site repository into cloud/nobuffer-site/repo for deployment.

Behavior:
1. Clones `vitorecomp/nobuffer-site` into `cloud/nobuffer-site/repo` (or updates it
   in-place if already cloned) on the specified branch/ref.
2. Uses SSH by default with automatic fallback to HTTPS (or `--https` directly in CI).
3. Optionally triggers a Google Cloud Build deployment (`--deploy`) using
   `cloud/nobuffer-site/cloudbuild.yaml` against the downloaded repository.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys

CLOUD_ROOT = Path(__file__).resolve().parent.parent
NOBUFFER_DIR = CLOUD_ROOT / "nobuffer-site"
DEFAULT_TARGET_DIR = NOBUFFER_DIR / "repo"
DEFAULT_CLOUDBUILD_CONFIG = NOBUFFER_DIR / "cloudbuild.yaml"
DEFAULT_SSH_URL = "git@github.com:vitorecomp/nobuffer-site.git"
DEFAULT_HTTPS_URL = "https://github.com/vitorecomp/nobuffer-site.git"
DEFAULT_BRANCH = "master"


def run_cmd(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=False,
        capture_output=True,
        text=True,
    )


def clone_nobuffer_repo(
    target_dir: Path,
    branch: str,
    ssh_url: str,
    https_url: str,
    prefer_https: bool = False,
    dry_run: bool = False,
) -> bool:
    primary_url = https_url if prefer_https else ssh_url
    fallback_url = None if prefer_https else https_url

    if dry_run:
        print(f"[dry-run] Would clone {primary_url} (branch: {branch}) -> {target_dir}")
        return True

    target_dir.parent.mkdir(parents=True, exist_ok=True)
    print(f"[clone] Cloning {primary_url} (branch: {branch}) -> {target_dir} ...")
    result = run_cmd(
        ["git", "clone", "--branch", branch, "--single-branch", primary_url, str(target_dir)]
    )
    if result.returncode == 0:
        print(f"[ok] Cloned nobuffer-site into {target_dir}")
        return True

    if fallback_url:
        print(
            f"[warn] SSH clone failed, retrying with HTTPS ({fallback_url})..."
        )
        result_https = run_cmd(
            ["git", "clone", "--branch", branch, "--single-branch", fallback_url, str(target_dir)]
        )
        if result_https.returncode == 0:
            print(f"[ok] Cloned nobuffer-site into {target_dir}")
            return True
        print(
            f"[error] Failed to clone nobuffer-site: {result_https.stderr.strip()}",
            file=sys.stderr,
        )
        return False

    print(
        f"[error] Failed to clone nobuffer-site: {result.stderr.strip()}",
        file=sys.stderr,
    )
    return False


def update_nobuffer_repo(
    target_dir: Path,
    branch: str,
    dry_run: bool = False,
) -> bool:
    if dry_run:
        print(
            f"[dry-run] Would fetch and update existing repo at {target_dir} to origin/{branch}"
        )
        return True

    print(f"[update] Updating existing nobuffer-site checkout at {target_dir} (branch: {branch}) ...")
    fetch_res = run_cmd(["git", "fetch", "origin", branch], cwd=target_dir)
    if fetch_res.returncode != 0:
        print(
            f"[error] Failed to fetch origin/{branch}: {fetch_res.stderr.strip()}",
            file=sys.stderr,
        )
        return False

    checkout_res = run_cmd(["git", "checkout", branch], cwd=target_dir)
    if checkout_res.returncode != 0:
        checkout_res = run_cmd(
            ["git", "checkout", "-B", branch, f"origin/{branch}"], cwd=target_dir
        )
        if checkout_res.returncode != 0:
            print(
                f"[error] Failed to checkout {branch}: {checkout_res.stderr.strip()}",
                file=sys.stderr,
            )
            return False

    pull_res = run_cmd(["git", "pull", "--ff-only", "origin", branch], cwd=target_dir)
    if pull_res.returncode != 0:
        print(
            f"[error] Failed to fast-forward {branch}: {pull_res.stderr.strip()}",
            file=sys.stderr,
        )
        return False

    print(f"[ok] Updated nobuffer-site at {target_dir}")
    return True


def deploy_nobuffer_repo(
    target_dir: Path,
    cloudbuild_config: Path,
    bucket_name: str,
    dry_run: bool = False,
) -> bool:
    if not cloudbuild_config.exists():
        print(
            f"[error] Cloud Build config not found: {cloudbuild_config}",
            file=sys.stderr,
        )
        return False

    cmd = [
        "gcloud",
        "builds",
        "submit",
        str(target_dir),
        f"--config={cloudbuild_config}",
        f"--substitutions=_BUCKET_NAME={bucket_name}",
    ]

    if dry_run:
        print(f"[dry-run] Would run: {' '.join(cmd)}")
        return True

    print(f"[deploy] Submitting Cloud Build for {target_dir} -> gs://{bucket_name} ...")
    result = subprocess.run(cmd, check=False)
    if result.returncode != 0:
        print("[error] Cloud Build submission failed.", file=sys.stderr)
        return False

    print(f"[ok] Deployed nobuffer-site to gs://{bucket_name}")
    return True


def sync_and_optionally_deploy(
    target_dir: Path,
    branch: str = DEFAULT_BRANCH,
    ssh_url: str = DEFAULT_SSH_URL,
    https_url: str = DEFAULT_HTTPS_URL,
    prefer_https: bool = False,
    deploy: bool = False,
    bucket_name: str | None = None,
    cloudbuild_config: Path = DEFAULT_CLOUDBUILD_CONFIG,
    dry_run: bool = False,
) -> int:
    if (target_dir / ".git").exists():
        ok = update_nobuffer_repo(target_dir, branch=branch, dry_run=dry_run)
    elif target_dir.exists() and any(target_dir.iterdir()):
        print(
            f"[error] Target directory {target_dir} already exists and is not a git repository.",
            file=sys.stderr,
        )
        return 1
    else:
        ok = clone_nobuffer_repo(
            target_dir,
            branch=branch,
            ssh_url=ssh_url,
            https_url=https_url,
            prefer_https=prefer_https,
            dry_run=dry_run,
        )

    if not ok:
        return 1

    if deploy:
        resolved_bucket = bucket_name or os.environ.get("GCS_BUCKET_NAME")
        if not resolved_bucket:
            print(
                "[error] --deploy requires --bucket or GCS_BUCKET_NAME environment variable.",
                file=sys.stderr,
            )
            return 1
        if not deploy_nobuffer_repo(
            target_dir,
            cloudbuild_config=cloudbuild_config,
            bucket_name=resolved_bucket,
            dry_run=dry_run,
        ):
            return 1

    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download/update the nobuffer-site repository into cloud/nobuffer-site/repo for deployment."
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=DEFAULT_TARGET_DIR,
        help=f"Target directory for cloning nobuffer-site (default: {DEFAULT_TARGET_DIR})",
    )
    parser.add_argument(
        "--branch",
        type=str,
        default=DEFAULT_BRANCH,
        help=f"Git branch to clone/update (default: {DEFAULT_BRANCH})",
    )
    parser.add_argument(
        "--https",
        action="store_true",
        help="Clone using HTTPS instead of trying SSH first.",
    )
    parser.add_argument(
        "--deploy",
        action="store_true",
        help="Submit a Google Cloud Build deployment after downloading/updating the repo.",
    )
    parser.add_argument(
        "--bucket",
        type=str,
        default=None,
        help="Target GCS bucket name for --deploy (defaults to $GCS_BUCKET_NAME).",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CLOUDBUILD_CONFIG,
        help=f"Path to cloudbuild.yaml (default: {DEFAULT_CLOUDBUILD_CONFIG})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview git clone/update and Cloud Build commands without making changes.",
    )
    args = parser.parse_args()

    sys.exit(
        sync_and_optionally_deploy(
            target_dir=args.target.expanduser().resolve(),
            branch=args.branch,
            prefer_https=args.https,
            deploy=args.deploy,
            bucket_name=args.bucket,
            cloudbuild_config=args.config.expanduser().resolve(),
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
