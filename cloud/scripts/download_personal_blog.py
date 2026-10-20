#!/usr/bin/env python3
"""Downloads or updates the personal-blog repository into cloud/personal-blog/repo for deployment.

Behavior:
1. Clones `vitorecomp/personal-blog` into `cloud/personal-blog/repo`
   (or updates it in-place if already cloned) on the specified branch/ref.
2. Uses SSH by default with automatic fallback to HTTPS (or `--https` directly in CI).
3. Optionally triggers a Google Cloud Build deployment (`--deploy`) using
   `cloud/personal-blog/cloudbuild.yaml` to build, push to Artifact Registry,
   and deploy to Google Cloud Run.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys

CLOUD_ROOT = Path(__file__).resolve().parent.parent
BLOG_DIR = CLOUD_ROOT / "personal-blog"
DEFAULT_TARGET_DIR = BLOG_DIR / "repo"
DEFAULT_CLOUDBUILD_CONFIG = BLOG_DIR / "cloudbuild.yaml"
DEFAULT_SSH_URL = "git@github.com:vitorecomp/personal-blog.git"
DEFAULT_HTTPS_URL = "https://github.com/vitorecomp/personal-blog.git"
DEFAULT_BRANCH = "main"
DEFAULT_REGION = "us-central1"
DEFAULT_AR_REPO = "personal-blog"
DEFAULT_SERVICE_NAME = "personal-blog"
DEFAULT_BLOG_URL = "https://blog.vitorx86.dev"


def run_cmd(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=False,
        capture_output=True,
        text=True,
    )


def clone_blog_repo(
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
        print(f"[ok] Cloned personal-blog into {target_dir}")
        return True

    if fallback_url:
        print(
            f"[warn] SSH clone failed, retrying with HTTPS ({fallback_url})..."
        )
        result_https = run_cmd(
            ["git", "clone", "--branch", branch, "--single-branch", fallback_url, str(target_dir)]
        )
        if result_https.returncode == 0:
            print(f"[ok] Cloned personal-blog into {target_dir}")
            return True
        print(
            f"[error] Failed to clone personal-blog: {result_https.stderr.strip()}",
            file=sys.stderr,
        )
        return False

    print(
        f"[error] Failed to clone personal-blog: {result.stderr.strip()}",
        file=sys.stderr,
    )
    return False


def update_blog_repo(
    target_dir: Path,
    branch: str,
    dry_run: bool = False,
) -> bool:
    if dry_run:
        print(
            f"[dry-run] Would fetch and update existing repo at {target_dir} to origin/{branch}"
        )
        return True

    print(
        f"[update] Updating existing personal-blog checkout at {target_dir} (branch: {branch}) ..."
    )
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

    print(f"[ok] Updated personal-blog at {target_dir}")
    return True


def deploy_blog_repo(
    target_dir: Path,
    cloudbuild_config: Path,
    region: str,
    ar_repo: str,
    service_name: str,
    blog_url: str,
    project_id: str = "compute-bench",
    dry_run: bool = False,
) -> bool:
    if not cloudbuild_config.exists():
        print(
            f"[error] Cloud Build config not found: {cloudbuild_config}",
            file=sys.stderr,
        )
        return False

    substitutions = (
        f"_REGION={region},"
        f"_AR_REPO={ar_repo},"
        f"_SERVICE_NAME={service_name}"
    )

    build_cmd = [
        "gcloud",
        "builds",
        "submit",
        str(target_dir),
        f"--project={project_id}",
        f"--config={cloudbuild_config}",
        f"--substitutions={substitutions}",
    ]

    image_uri = f"{region}-docker.pkg.dev/{project_id}/{ar_repo}/{service_name}:latest"
    deploy_cmd = [
        "gcloud",
        "run",
        "services",
        "update",
        service_name,
        f"--project={project_id}",
        f"--region={region}",
        f"--image={image_uri}",
        f"--update-env-vars=NODE_ENV=production,url={blog_url},security__staffDeviceVerification=false",
        "--quiet",
    ]

    seed_script = Path(__file__).resolve().parent / "seed_ghost_admin.py"
    seed_cmd = [
        sys.executable,
        str(seed_script),
        f"--blog-url={blog_url}",
    ]

    if dry_run:
        print(f"[dry-run] Would run: {' '.join(build_cmd)}")
        print(f"[dry-run] Would run: {' '.join(deploy_cmd)}")
        print(f"[dry-run] Would run: {' '.join(seed_cmd)} --dry-run")
        return True

    print(
        f"[deploy] Submitting Cloud Build for {target_dir} -> Artifact Registry '{ar_repo}/{service_name}' ({region}) ..."
    )
    result = subprocess.run(build_cmd, check=False)
    if result.returncode != 0:
        print("[error] Cloud Build submission failed.", file=sys.stderr)
        return False

    print(
        f"[deploy] Updating Cloud Run service '{service_name}' ({region}) with image {image_uri} ..."
    )
    deploy_res = subprocess.run(deploy_cmd, check=False)
    if deploy_res.returncode != 0:
        print("[error] Cloud Run service update failed.", file=sys.stderr)
        return False

    if seed_script.exists():
        seed_res = subprocess.run(seed_cmd, check=False)
        if seed_res.returncode != 0:
            print("[error] Ghost Admin Owner seeding failed.", file=sys.stderr)
            return False

    print(f"[ok] Deployed personal-blog to Cloud Run service '{service_name}'")
    return True


def sync_and_optionally_deploy(
    target_dir: Path,
    branch: str = DEFAULT_BRANCH,
    ssh_url: str = DEFAULT_SSH_URL,
    https_url: str = DEFAULT_HTTPS_URL,
    prefer_https: bool = False,
    deploy: bool = False,
    region: str = DEFAULT_REGION,
    ar_repo: str = DEFAULT_AR_REPO,
    service_name: str = DEFAULT_SERVICE_NAME,
    blog_url: str = DEFAULT_BLOG_URL,
    cloudbuild_config: Path = DEFAULT_CLOUDBUILD_CONFIG,
    dry_run: bool = False,
) -> int:
    if (target_dir / ".git").exists():
        ok = update_blog_repo(target_dir, branch=branch, dry_run=dry_run)
    elif target_dir.exists() and any(target_dir.iterdir()):
        print(
            f"[error] Target directory {target_dir} already exists and is not a git repository.",
            file=sys.stderr,
        )
        return 1
    else:
        ok = clone_blog_repo(
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
        if not deploy_blog_repo(
            target_dir,
            cloudbuild_config=cloudbuild_config,
            region=region,
            ar_repo=ar_repo,
            service_name=service_name,
            blog_url=blog_url,
            dry_run=dry_run,
        ):
            return 1

    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download/update the personal-blog repository into cloud/personal-blog/repo for Cloud Run deployment."
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=DEFAULT_TARGET_DIR,
        help=f"Target directory for cloning personal-blog (default: {DEFAULT_TARGET_DIR})",
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
        "--region",
        type=str,
        default=os.environ.get("GCP_REGION", DEFAULT_REGION),
        help=f"GCP region for Artifact Registry and Cloud Run (default: {DEFAULT_REGION}).",
    )
    parser.add_argument(
        "--ar-repo",
        type=str,
        default=os.environ.get("GAR_BLOG_REPO", DEFAULT_AR_REPO),
        help=f"Artifact Registry repository name (default: {DEFAULT_AR_REPO}).",
    )
    parser.add_argument(
        "--service",
        type=str,
        default=os.environ.get("CLOUD_RUN_BLOG_SERVICE", DEFAULT_SERVICE_NAME),
        help=f"Cloud Run service name (default: {DEFAULT_SERVICE_NAME}).",
    )
    parser.add_argument(
        "--blog-url",
        type=str,
        default=os.environ.get("BLOG_URL", DEFAULT_BLOG_URL),
        help=f"Canonical Ghost public URL (default: {DEFAULT_BLOG_URL}).",
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
            region=args.region,
            ar_repo=args.ar_repo,
            service_name=args.service,
            blog_url=args.blog_url,
            cloudbuild_config=args.config.expanduser().resolve(),
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
