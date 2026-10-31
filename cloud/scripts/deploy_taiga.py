#!/usr/bin/env python3
"""Validates and deploys the self-contained cloud/taiga workload to Google Cloud Run.

Behavior:
1. Verifies that all required build artifacts exist inside `cloud/taiga/`
   (`Dockerfile`, `nginx.conf`, `docker-entrypoint.sh`, `cloudbuild.yaml`).
2. Submits a Google Cloud Build deployment (`--deploy`) using
   `cloud/taiga/cloudbuild.yaml` to build and push the unified Taiga image
   to Artifact Registry, updates the Cloud Run service, and verifies readiness
   via `seed_taiga_admin.py`.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse

CLOUD_ROOT = Path(__file__).resolve().parent.parent
TAIGA_DIR = CLOUD_ROOT / "taiga"
DEFAULT_CLOUDBUILD_CONFIG = TAIGA_DIR / "cloudbuild.yaml"
DEFAULT_REGION = "us-central1"
DEFAULT_AR_REPO = "taiga"
DEFAULT_SERVICE_NAME = "taiga"
DEFAULT_TAIGA_URL = "https://taiga.vitorx86.dev"
REQUIRED_FILES = (
    "Dockerfile",
    "nginx.conf",
    "docker-entrypoint.sh",
    "cloudbuild.yaml",
)


def validate_taiga_dir(source_dir: Path, dry_run: bool = False) -> bool:
    missing = [name for name in REQUIRED_FILES if not (source_dir / name).exists()]
    if missing:
        print(
            f"[error] Missing required Taiga build files in {source_dir}: {', '.join(missing)}",
            file=sys.stderr,
        )
        return False

    if dry_run:
        print(
            f"[dry-run] Verified Taiga build context at {source_dir} ({', '.join(REQUIRED_FILES)})"
        )
    else:
        print(f"[ok] Verified Taiga build context at {source_dir}")
    return True


def deploy_taiga_service(
    source_dir: Path,
    cloudbuild_config: Path,
    region: str,
    ar_repo: str,
    service_name: str,
    taiga_url: str,
    project_id: str = "compute-bench",
    dry_run: bool = False,
) -> bool:
    if not cloudbuild_config.exists():
        print(
            f"[error] Cloud Build config not found: {cloudbuild_config}",
            file=sys.stderr,
        )
        return False

    parsed_url = urlparse(taiga_url)
    scheme = parsed_url.scheme or "https"
    domain = parsed_url.netloc or "taiga.vitorx86.dev"

    substitutions = (
        f"_REGION={region},"
        f"_AR_REPO={ar_repo},"
        f"_SERVICE_NAME={service_name}"
    )

    build_cmd = [
        "gcloud",
        "builds",
        "submit",
        str(source_dir),
        f"--project={project_id}",
        f"--config={cloudbuild_config}",
        f"--substitutions={substitutions}",
    ]

    runtime_sa = os.environ.get(
        "TAIGA_RUNTIME_SA", f"taiga-run@{project_id}.iam.gserviceaccount.com"
    )
    image_uri = f"{region}-docker.pkg.dev/{project_id}/{ar_repo}/{service_name}:latest"
    deploy_cmd = [
        "gcloud",
        "run",
        "services",
        "update",
        service_name,
        f"--project={project_id}",
        f"--region={region}",
        f"--service-account={runtime_sa}",
        f"--image={image_uri}",
        (
            f"--update-env-vars="
            f"TAIGA_SITES_SCHEME={scheme},"
            f"TAIGA_SITES_DOMAIN={domain},"
            f"TAIGA_URL={taiga_url},"
            f"PUBLIC_REGISTER_ENABLED=False,"
            f"ENABLE_TELEMETRY=False,"
            f"CELERY_ENABLED=False"
        ),
        "--no-invoker-iam-check",
        "--quiet",
    ]

    seed_script = Path(__file__).resolve().parent / "seed_taiga_admin.py"
    seed_cmd = [
        sys.executable,
        str(seed_script),
        f"--taiga-url={taiga_url}",
    ]

    if dry_run:
        print(f"[dry-run] Would run: {' '.join(build_cmd)}")
        print(f"[dry-run] Would run: {' '.join(deploy_cmd)}")
        print(f"[dry-run] Would run: {' '.join(seed_cmd)} --dry-run")
        return True

    print(
        f"[deploy] Submitting Cloud Build for {source_dir} -> Artifact Registry '{ar_repo}/{service_name}' ({region}) ..."
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
            print("[error] Taiga Admin verification failed.", file=sys.stderr)
            return False

    print(f"[ok] Deployed Taiga to Cloud Run service '{service_name}'")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate and deploy the cloud/taiga workload to Google Cloud Run."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=TAIGA_DIR,
        help=f"Source directory containing Taiga Dockerfile and configs (default: {TAIGA_DIR})",
    )
    parser.add_argument(
        "--deploy",
        action="store_true",
        help="Submit a Google Cloud Build and Cloud Run deployment after validating the build context.",
    )
    parser.add_argument(
        "--project",
        type=str,
        default=os.environ.get("GCP_PROJECT_ID", "compute-bench"),
        help="Target GCP Project ID (default: compute-bench).",
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
        default=os.environ.get("GAR_TAIGA_REPO", DEFAULT_AR_REPO),
        help=f"Artifact Registry repository name (default: {DEFAULT_AR_REPO}).",
    )
    parser.add_argument(
        "--service",
        type=str,
        default=os.environ.get("CLOUD_RUN_TAIGA_SERVICE", DEFAULT_SERVICE_NAME),
        help=f"Cloud Run service name (default: {DEFAULT_SERVICE_NAME}).",
    )
    parser.add_argument(
        "--taiga-url",
        type=str,
        default=os.environ.get("TAIGA_URL", DEFAULT_TAIGA_URL),
        help=f"Canonical Taiga public URL (default: {DEFAULT_TAIGA_URL}).",
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
        help="Preview validation and Cloud Build / Cloud Run commands without making changes.",
    )
    args = parser.parse_args()

    source_dir = args.source.expanduser().resolve()
    cloudbuild_config = args.config.expanduser().resolve()

    if not validate_taiga_dir(source_dir, dry_run=args.dry_run):
        sys.exit(1)

    if args.deploy:
        if not deploy_taiga_service(
            source_dir=source_dir,
            cloudbuild_config=cloudbuild_config,
            region=args.region,
            ar_repo=args.ar_repo,
            service_name=args.service,
            taiga_url=args.taiga_url,
            project_id=args.project,
            dry_run=args.dry_run,
        ):
            sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
