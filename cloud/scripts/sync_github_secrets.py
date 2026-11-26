#!/usr/bin/env python3
"""Syncs private/personal infrastructure settings from the root `.env` to GitHub Secrets.

Because this repository is public, domains, emails, Cloud Run upstream URLs, GCP project/bucket
identifiers, WIF provider identifiers, and VM `known_hosts` entries are stored as **GitHub Secrets**
(rather than plaintext Variables) so GitHub Actions automatically masks (`***`) them in public logs.

Behavior (idempotent):
1. Reads key-value pairs from the gitignored root `.env` (falls back to `.env.example` in `--dry-run`
   when `.env` is absent, e.g. in CI). Never prints secret values — only secret/variable names.
2. Ensures `taiga-prod` and `blog-prod` GitHub Environments exist without altering branch/reviewer policies.
3. Uploads Repository Secrets and per-environment Secrets (`taiga-prod`, `blog-prod`) via `gh secret set`
   over stdin (values never appear in process argv).
4. Deletes legacy unmasked personal GitHub Variables (`GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`, `BLOG_ADMIN_EMAIL`,
   `TAIGA_ADMIN_EMAIL`, `DEPLOY_KNOWN_HOSTS`) unless `--keep-legacy-vars` is passed.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parent.parent.parent
DEFAULT_ENV_FILE = REPO_ROOT / ".env"
EXAMPLE_ENV_FILE = REPO_ROOT / ".env.example"

REPO_SECRET_KEYS: tuple[str, ...] = (
    "ROOT_DOMAIN",
    "TAIGA_DOMAIN",
    "TAIGA_URL",
    "BLOG_DOMAIN",
    "BLOG_URL",
    "ACME_EMAIL",
    "ADMIN_NAME",
    "BLOG_ADMIN_NAME",
    "BLOG_TITLE",
    "BLOG_THEME_NAME",
    "GCP_PROJECT_ID",
    "GCP_REGION",
    "TF_STATE_BUCKET",
    "BACKUP_BUCKET",
    "TAIGA_MEDIA_BUCKET",
    "TAIGA_RUN_SA",
    "TAIGA_UPSTREAM",
    "GCP_WIF_PROVIDER",
    "GCP_DEPLOY_SA",
)

LEGACY_REPO_VARS: tuple[str, ...] = (
    "GCP_WIF_PROVIDER",
    "GCP_DEPLOY_SA",
    "BLOG_ADMIN_EMAIL",
)

LEGACY_ENV_VARS: dict[str, tuple[str, ...]] = {
    "taiga-prod": ("TAIGA_ADMIN_EMAIL", "DEPLOY_KNOWN_HOSTS"),
    "blog-prod": ("BLOG_ADMIN_EMAIL", "DEPLOY_KNOWN_HOSTS"),
}


def parse_dotenv(path: Path, warn_perms: bool = True) -> dict[str, str]:
    if not path.is_file():
        return {}
    if warn_perms and (path.stat().st_mode & 0o077):
        print(f"[warn] {path} is readable by group/others; tightening to 0600.", file=sys.stderr)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        elif " #" in val:
            val = val.split(" #", 1)[0].strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            values[key] = val
    return values


def ensure_gh_authenticated(dotenv_vals: dict[str, str]) -> dict[str, str]:
    if not shutil.which("gh"):
        raise SystemExit("[error] GitHub CLI ('gh') is not installed or not on PATH.")
    env = dict(os.environ)
    # Prefer an already-authenticated `gh auth login` session over a potentially read-only/expired GITHUB_TOKEN in .env.
    if not env.get("GH_TOKEN") and dotenv_vals.get("GH_TOKEN"):
        env["GH_TOKEN"] = dotenv_vals["GH_TOKEN"]
    probe = subprocess.run(["gh", "auth", "status"], env=env, capture_output=True, text=True, check=False)
    if probe.returncode == 0:
        return env
    tok = dotenv_vals.get("GITHUB_TOKEN") or ""
    if tok:
        env["GH_TOKEN"] = tok
        probe = subprocess.run(["gh", "auth", "status"], env=env, capture_output=True, text=True, check=False)
        if probe.returncode == 0:
            return env
    raise SystemExit("[error] 'gh' is not authenticated. Run 'gh auth login' or set GH_TOKEN in .env.")


def ensure_environment(repo: str, env_name: str, gh_env: dict[str, str], dry_run: bool) -> None:
    if dry_run:
        print(f"[dry-run] Ensure GitHub Environment '{env_name}' exists on {repo}")
        return
    probe = subprocess.run(
        ["gh", "api", f"repos/{repo}/environments/{env_name}"],
        env=gh_env,
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        create = subprocess.run(
            ["gh", "api", "-X", "PUT", f"repos/{repo}/environments/{env_name}"],
            env=gh_env,
            capture_output=True,
            text=True,
            check=False,
        )
        if create.returncode != 0:
            raise SystemExit(f"[error] Failed creating environment '{env_name}': {create.stderr.strip()}")
        print(f"[ok] Created GitHub Environment '{env_name}' on {repo}")


def set_secret(
    repo: str,
    name: str,
    value: str,
    gh_env: dict[str, str],
    dry_run: bool,
    target_env: str | None = None,
) -> None:
    scope = f"environment '{target_env}'" if target_env else "repository"
    if dry_run:
        print(f"[dry-run] gh secret set {name} --repo {repo}" + (f" --env {target_env}" if target_env else "") + " (<redacted>)")
        return
    cmd = ["gh", "secret", "set", name, "--repo", repo]
    if target_env:
        cmd += ["--env", target_env]
    res = subprocess.run(cmd, input=value, env=gh_env, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise SystemExit(f"[error] Failed setting secret {name} on {scope}: {res.stderr.strip()}")
    print(f"[ok] Synced secret {name} -> {scope}")


def prune_legacy_variables(repo: str, gh_env: dict[str, str], dry_run: bool) -> None:
    if dry_run:
        for var in LEGACY_REPO_VARS:
            print(f"[dry-run] Remove legacy unmasked repo variable if present: {var}")
        for env_name, env_vars in LEGACY_ENV_VARS.items():
            for var in env_vars:
                print(f"[dry-run] Remove legacy unmasked {env_name} variable if present: {var}")
        return

    def existing_var_names(extra: list[str]) -> set[str]:
        res = subprocess.run(
            ["gh", "variable", "list", "--repo", repo, *extra, "--json", "name"],
            env=gh_env,
            capture_output=True,
            text=True,
            check=False,
        )
        if res.returncode != 0:
            return set()
        return {item["name"] for item in json.loads(res.stdout or "[]")}

    present_repo = existing_var_names([])
    for var in LEGACY_REPO_VARS:
        if var in present_repo:
            subprocess.run(["gh", "variable", "delete", var, "--repo", repo], env=gh_env, check=False, capture_output=True)
            print(f"[ok] Deleted legacy unmasked repository variable {var}")

    for env_name, env_vars in LEGACY_ENV_VARS.items():
        present_env = existing_var_names(["--env", env_name])
        for var in env_vars:
            if var in present_env:
                subprocess.run(
                    ["gh", "variable", "delete", var, "--repo", repo, "--env", env_name],
                    env=gh_env,
                    check=False,
                    capture_output=True,
                )
                print(f"[ok] Deleted legacy unmasked '{env_name}' variable {var}")


def sync(env_file: Path, repo_override: str, keep_legacy_vars: bool, dry_run: bool) -> int:
    source_file = env_file
    if not source_file.is_file():
        if dry_run and EXAMPLE_ENV_FILE.is_file():
            source_file = EXAMPLE_ENV_FILE
        else:
            print(f"[error] {env_file} not found. Copy .env.example to .env and fill in your values.", file=sys.stderr)
            return 1

    vals = parse_dotenv(source_file, warn_perms=(source_file != EXAMPLE_ENV_FILE and not dry_run))
    # Explicit process environment overrides file entries when non-empty.
    for k, v in os.environ.items():
        if v and k in vals:
            vals[k] = v

    # Derive TAIGA_URL / BLOG_URL from domains if omitted.
    if not vals.get("TAIGA_URL") and vals.get("TAIGA_DOMAIN"):
        vals["TAIGA_URL"] = f"https://{vals['TAIGA_DOMAIN']}"
    if not vals.get("BLOG_URL") and vals.get("BLOG_DOMAIN"):
        vals["BLOG_URL"] = f"https://{vals['BLOG_DOMAIN']}"

    repo = (repo_override or vals.get("GITHUB_REPO") or "vitorecomp/personal-infra").strip()
    if "/" not in repo:
        print(f"[error] Invalid GitHub repository '{repo}' (expected owner/repo).", file=sys.stderr)
        return 1

    gh_env = dict(os.environ) if dry_run else ensure_gh_authenticated(vals)
    print(f"[{'dry-run' if dry_run else 'sync'}] Source: {source_file.relative_to(REPO_ROOT) if source_file.is_relative_to(REPO_ROOT) else source_file} -> {repo}")

    for key in REPO_SECRET_KEYS:
        val = vals.get(key, "").strip()
        if val:
            set_secret(repo, key, val, gh_env, dry_run, target_env=None)

    ensure_environment(repo, "taiga-prod", gh_env, dry_run)
    ensure_environment(repo, "blog-prod", gh_env, dry_run)

    taiga_email = (vals.get("TAIGA_ADMIN_EMAIL") or vals.get("ACME_EMAIL") or "").strip()
    if taiga_email:
        set_secret(repo, "TAIGA_ADMIN_EMAIL", taiga_email, gh_env, dry_run, target_env="taiga-prod")
    taiga_kh = (vals.get("TAIGA_DEPLOY_KNOWN_HOSTS") or vals.get("DEPLOY_KNOWN_HOSTS") or "").strip()
    if taiga_kh:
        set_secret(repo, "DEPLOY_KNOWN_HOSTS", taiga_kh, gh_env, dry_run, target_env="taiga-prod")

    blog_email = (vals.get("BLOG_ADMIN_EMAIL") or vals.get("ACME_EMAIL") or "").strip()
    if blog_email:
        set_secret(repo, "BLOG_ADMIN_EMAIL", blog_email, gh_env, dry_run, target_env="blog-prod")
    blog_kh = (vals.get("BLOG_DEPLOY_KNOWN_HOSTS") or vals.get("DEPLOY_KNOWN_HOSTS") or "").strip()
    if blog_kh:
        set_secret(repo, "DEPLOY_KNOWN_HOSTS", blog_kh, gh_env, dry_run, target_env="blog-prod")

    if not keep_legacy_vars:
        prune_legacy_variables(repo, gh_env, dry_run)

    print(f"[{'dry-run' if dry_run else 'ok'}] GitHub Secrets sync {'preview ' if dry_run else ''}complete.")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync private/personal settings from root .env to GitHub Secrets.")
    parser.add_argument("--env-file", type=Path, default=DEFAULT_ENV_FILE, help="Path to .env file (default: repo root .env)")
    parser.add_argument("--repo", default="", help="Override GitHub owner/repo (default: GITHUB_REPO in .env)")
    parser.add_argument("--keep-legacy-vars", action="store_true", help="Do not delete legacy unmasked personal GitHub Variables")
    parser.add_argument("--dry-run", action="store_true", help="Print secret/variable actions without calling GitHub")
    args = parser.parse_args()
    sys.exit(sync(args.env_file.expanduser().resolve(), args.repo, args.keep_legacy_vars, args.dry_run))


if __name__ == "__main__":
    main()
