#!/usr/bin/env python3
"""Deploys a docker compose stack from cloud/<stack>/ to a VM over SSH (one path for local and CI).

Steps (all idempotent, re-running converges):
1. Validates cloud/<stack>/stack.json and its required files locally.
2. rsyncs the stack directory to <remote-root>/<stack>/ (never touching .env, app/, .migration/)
   and ships backup_stack.py to <remote-root>/.ops/.
3. Optionally creates the remote .env from .env.example (--init-env): `__generate__` values are
   generated ON THE VM, `__required__` values must be filled in by hand. Existing files are kept.
4. Preflights the remote .env: exists, mode 0600, every key from .env.example present and filled.
   Only key names are ever printed, never values.
5. Clones/fetches the app repo (if stack.json has one) at --app-ref.
6. Under flock: pre_build hook, `compose pull`, `compose build --pull`, `compose up -d --wait`, prune.
7. HTTPS health check against the VM IP with the real SNI/Host (never through public DNS).
8. Runs the stack's post-deploy seed script and records a .deployed marker.

`--dry-run` prints every command without opening any network connection.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CLOUD_ROOT = SCRIPT_DIR.parent
REPO_ROOT = CLOUD_ROOT.parent
DEFAULT_REMOTE_ROOT = "/opt/stacks"
APP_REF_PATTERN = re.compile(r"^(?:[0-9a-f]{7,40}|[A-Za-z0-9._/-]{1,100})$")
RSYNC_EXCLUDES = (".env", "app/", ".migration/", ".deployed", ".deploy.lock", "compose.local.yml", "repo/")
PLACEHOLDERS = ("__generate__", "__required__")


@dataclass
class Stack:
    name: str
    path: Path
    domain: str
    health_path: str
    required_files: list[str]
    app_repo: dict[str, str] | None
    pre_build: list[str] | None
    post_deploy: dict[str, str] | None


def available_stacks() -> list[str]:
    return sorted(p.parent.name for p in CLOUD_ROOT.glob("*/stack.json"))


def load_stack(name: str) -> Stack:
    path = CLOUD_ROOT / name
    meta_file = path / "stack.json"
    if not meta_file.is_file():
        raise SystemExit(f"[error] {meta_file} not found (available: {', '.join(available_stacks())})")
    meta = json.loads(meta_file.read_text())
    return Stack(
        name=meta["name"],
        path=path,
        domain=meta["domain"],
        health_path=meta.get("health_path", "/"),
        required_files=list(meta.get("required_files", [])),
        app_repo=meta.get("app_repo"),
        pre_build=meta.get("pre_build"),
        post_deploy=meta.get("post_deploy"),
    )


def validate_stack_files(stack: Stack) -> bool:
    missing = [f for f in stack.required_files if not (stack.path / f).exists()]
    if missing:
        print(f"[error] {stack.path} is missing required files: {', '.join(missing)}", file=sys.stderr)
        return False
    print(f"[ok] {stack.name}: required files present ({len(stack.required_files)})")
    return True


def validate_app_ref(ref: str) -> bool:
    if not APP_REF_PATTERN.match(ref) or ".." in ref or ref.startswith("-"):
        print(f"[error] Refusing suspicious --app-ref {ref!r}", file=sys.stderr)
        return False
    return True


class Remote:
    """Thin SSH/rsync wrapper with connection multiplexing and dry-run support."""

    def __init__(self, host: str, identity_file: Path | None, dry_run: bool, strict_host_key: bool = True) -> None:
        self.host = host
        self.dry_run = dry_run
        self._control_dir = tempfile.mkdtemp(prefix="pi-ssh-") if not dry_run else "/tmp/pi-ssh-dry-run"
        self.ssh_opts = [
            "-o", "BatchMode=yes",
            "-o", f"StrictHostKeyChecking={'yes' if strict_host_key else 'accept-new'}",
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={self._control_dir}/cm-%C",
            "-o", "ControlPersist=60",
            "-o", "ServerAliveInterval=30",
        ]
        if identity_file:
            self.ssh_opts += ["-i", str(identity_file), "-o", "IdentitiesOnly=yes"]

    def close(self) -> None:
        if self.dry_run:
            return
        subprocess.run(["ssh", *self.ssh_opts, "-O", "exit", self.host], capture_output=True, check=False)
        shutil.rmtree(self._control_dir, ignore_errors=True)

    def run(
        self,
        script: str,
        *,
        input_text: str | None = None,
        capture: bool = False,
        describe: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Runs a bash script on the remote host (script passed as an argument to `bash -c`)."""
        cmd = ["ssh", *self.ssh_opts, self.host, "bash -c " + shlex.quote("set -euo pipefail\n" + script)]
        if self.dry_run:
            label = describe or script.strip().splitlines()[0]
            print(f"[dry-run] Would run on {self.host}: {label}")
            return subprocess.CompletedProcess(cmd, 0, "", "")
        return subprocess.run(
            cmd,
            input=input_text,
            text=True,
            capture_output=capture,
            check=False,
        )

    def rsync(self, src: str, dest: str, extra: list[str] | None = None) -> bool:
        cmd = [
            "rsync", "-az", "--delete",
            *(extra or []),
            "-e", shlex.join(["ssh", *self.ssh_opts]),
            src, f"{self.host}:{dest}",
        ]
        if self.dry_run:
            print(f"[dry-run] Would run: {shlex.join(cmd)}")
            return True
        result = subprocess.run(cmd, check=False)
        if result.returncode != 0:
            print(f"[error] rsync {src} -> {dest} failed ({result.returncode})", file=sys.stderr)
            return False
        return True

    def resolve_ip(self) -> str:
        """Resolves the real address behind an SSH alias/user@host via `ssh -G`."""
        hostname = self.host.split("@", 1)[-1]
        result = subprocess.run(["ssh", "-G", self.host], capture_output=True, text=True, check=False)
        for line in result.stdout.splitlines():
            if line.startswith("hostname "):
                hostname = line.split(" ", 1)[1].strip()
                break
        return socket.gethostbyname(hostname)


# ---------------------------------------------------------------------------
# Remote .env handling (values never leave the VM, only key names are printed)
# ---------------------------------------------------------------------------

_ENV_TOOL = r'''
import os, secrets, stat, sys
mode, stack_dir = sys.argv[1], sys.argv[2]
env_path = os.path.join(stack_dir, ".env")
example_path = os.path.join(stack_dir, ".env.example")

def parse(path):
    out = {}
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out

if mode == "init":
    if os.path.exists(env_path):
        print("[ok] .env already exists; leaving it untouched")
        sys.exit(0)
    generated, required, lines = [], [], []
    with open(example_path) as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and "=" in stripped:
                key, value = stripped.split("=", 1)
                if value.strip() == "__generate__":
                    line = f"{key.strip()}={secrets.token_urlsafe(32)}"
                    generated.append(key.strip())
                elif value.strip() == "__required__":
                    required.append(key.strip())
            lines.append(line)
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"[ok] Created .env (generated on the VM: {', '.join(generated) or 'none'})")
    if required:
        print(f"[warn] Fill in by hand before deploying: {', '.join(required)}")
    sys.exit(0)

if mode == "check":
    if not os.path.exists(env_path):
        print("[error] .env is missing (run with --init-env or create it from .env.example)")
        sys.exit(3)
    perms = stat.S_IMODE(os.stat(env_path).st_mode)
    if perms & 0o077:
        print(f"[error] .env mode is {perms:o}; run: chmod 600 {env_path}")
        sys.exit(4)
    env, example = parse(env_path), parse(example_path)
    with open(os.path.join(stack_dir, "compose.yml")) as fh:
        compose_text = fh.read()
    # Keys interpolated by compose.yml block the deploy; the rest (e.g. backup credentials)
    # only warn, because nothing at runtime depends on them.
    used = lambda k: ("${" + k + "}" in compose_text) or ("${" + k + ":" in compose_text)
    bad = [k for k in example if k not in env or env[k] in ("", "__generate__", "__required__")]
    blocking = [k for k in bad if used(k)]
    optional = [k for k in bad if not used(k)]
    if optional:
        print(f"[warn] .env keys not set yet (not used by compose; backups stay disabled): {', '.join(optional)}")
    if blocking:
        print(f"[error] .env keys missing/empty/placeholder: {', '.join(blocking)}")
        sys.exit(5)
    tls = "internal" if env.get("CADDY_TLS", "").strip() == "internal" else "acme"
    print(f"[ok] .env has every key from .env.example (tls={tls})")
    print(f"TLS_MODE={tls}")
    sys.exit(0)
'''


def remote_env(remote: Remote, mode: str, stack_dir: str) -> tuple[bool, str]:
    result = remote.run(
        f"python3 - {shlex.quote(mode)} {shlex.quote(stack_dir)} <<'PYEOF'\n{_ENV_TOOL}\nPYEOF",
        capture=True,
        describe=f"python3 .env {mode} in {stack_dir}",
    )
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.splitlines():
        if not line.startswith("TLS_MODE="):
            print(line)
    tls_mode = "acme"
    for line in output.splitlines():
        if line.startswith("TLS_MODE="):
            tls_mode = line.split("=", 1)[1].strip()
    return result.returncode == 0, tls_mode


# ---------------------------------------------------------------------------
# HTTPS health check (connects to an IP, keeps SNI/Host = public domain)
# ---------------------------------------------------------------------------


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, connect_ip: str, server_name: str, insecure: bool, timeout: float) -> None:
        context = ssl.create_default_context()
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        super().__init__(server_name, 443, timeout=timeout, context=context)
        self._connect_ip = connect_ip

    def connect(self) -> None:
        sock = socket.create_connection((self._connect_ip, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def https_check(
    connect_ip: str,
    domain: str,
    path: str,
    insecure: bool = False,
    retries: int = 20,
    delay: float = 6.0,
) -> bool:
    for attempt in range(1, retries + 1):
        try:
            conn = _PinnedHTTPSConnection(connect_ip, domain, insecure, timeout=15.0)
            try:
                conn.request("GET", path, headers={"Host": domain, "User-Agent": "personal-infra-deploy/1.0"})
                resp = conn.getresponse()
                resp.read()
                if resp.status == 200:
                    issuer = ""
                    if not insecure and conn.sock is not None:
                        cert = conn.sock.getpeercert() or {}
                        issuer = dict(x[0] for x in cert.get("issuer", ())).get("organizationName", "")
                    note = f", issuer {issuer}" if issuer else (", certificate NOT verified" if insecure else "")
                    print(f"[ok] https://{domain}{path} via {connect_ip} -> 200{note}")
                    return True
                print(f"[wait] https://{domain}{path} via {connect_ip} -> {resp.status} ({attempt}/{retries})")
            finally:
                conn.close()
        except (OSError, ssl.SSLError, http.client.HTTPException) as err:
            print(f"[wait] https://{domain}{path} via {connect_ip}: {err} ({attempt}/{retries})")
        time.sleep(delay)
    print(f"[error] Health check failed for https://{domain}{path} via {connect_ip}", file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------


def local_git_sha() -> str:
    result = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"], capture_output=True, text=True)
    return result.stdout.strip() or "unknown"


_STALE_SERVICES = r"""
import json, subprocess, sys
project = json.load(sys.stdin)
name = project.get("name", "")
stale = []
for svc, cfg in project.get("services", {}).items():
    image = cfg.get("image")
    if not image:
        continue
    cid = subprocess.run(["docker", "ps", "-q", "--filter", f"label=com.docker.compose.project={name}",
                          "--filter", f"label=com.docker.compose.service={svc}"], capture_output=True, text=True).stdout.split()
    want = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", image], capture_output=True, text=True).stdout.strip()
    for c in cid:
        have = subprocess.run(["docker", "inspect", "-f", "{{.Image}}", c], capture_output=True, text=True).stdout.strip()
        if want and have and want != have:
            stale.append(svc)
            break
print(" ".join(stale))
"""


def build_up_script(stack: Stack, stack_dir: str, skip_build: bool) -> str:
    compose = f"docker compose -p {shlex.quote(stack.name)} -f compose.yml"
    lines = [
        f"cd {shlex.quote(stack_dir)}",
        "exec 9>.deploy.lock",
        "flock -n 9 || { echo '[error] another deploy holds .deploy.lock' >&2; exit 75; }",
    ]
    if stack.pre_build:
        app_dir = f"{stack_dir}/{(stack.app_repo or {}).get('path', 'app')}"
        hook = [part.replace("{app}", app_dir) for part in stack.pre_build]
        lines += ["echo '[deploy] pre_build hook'", shlex.join(hook)]
    lines.append(f"{compose} pull --ignore-buildable --quiet")
    if not skip_build:
        # No provenance/SBOM attestations: unchanged sources then rebuild to the same image ID.
        lines.append(f"BUILDX_NO_DEFAULT_ATTESTATIONS=1 {compose} build --pull")
    lines += [
        f"{compose} up -d --remove-orphans --wait --wait-timeout 900",
        # `up` compares service config, not the image behind a tag, so a rebuilt `app:local` or a
        # re-pulled tag would keep the old container. Recreate exactly the services that drifted.
        f"stale=$({compose} config --format json | python3 -c {shlex.quote(_STALE_SERVICES)})",
        f'if [ -n "$stale" ]; then echo "[deploy] recreating services on a new image: $stale"; '
        f"{compose} up -d --no-deps --force-recreate --wait --wait-timeout 900 $stale; fi",
        f"{compose} ps",
        "docker image prune -f >/dev/null",
        "docker builder prune -f --filter until=168h >/dev/null",
    ]
    return "\n".join(lines)


def deploy(args: argparse.Namespace) -> int:
    stack = load_stack(args.stack)
    if not validate_stack_files(stack):
        return 1

    app_ref = args.app_ref or (stack.app_repo or {}).get("default_ref", "")
    if stack.app_repo and not validate_app_ref(app_ref):
        return 1

    remote_root = args.remote_root.rstrip("/")
    stack_dir = f"{remote_root}/{stack.name}"
    remote = Remote(args.host, args.identity_file, args.dry_run)
    try:
        # 1. Preflight docker + directories
        result = remote.run(
            f"command -v docker >/dev/null || {{ echo '[error] docker missing; run bootstrap_vm.py' >&2; exit 2; }}\n"
            f"docker compose version >/dev/null\n"
            f"mkdir -p {shlex.quote(stack_dir)} {shlex.quote(remote_root + '/.ops')}",
            describe=f"preflight docker + mkdir {stack_dir}",
        )
        if result.returncode != 0:
            print(f"[error] Preflight failed on {args.host}", file=sys.stderr)
            return 1

        # 2. Sync stack files + backup tool
        excludes = [f"--exclude={item}" for item in RSYNC_EXCLUDES]
        if not remote.rsync(f"{stack.path}/", f"{stack_dir}/", excludes):
            return 1
        if not remote.rsync(str(SCRIPT_DIR / "backup_stack.py"), f"{remote_root}/.ops/backup_stack.py", ["--chmod=F755"]):
            return 1
        print(f"[ok] Synced {stack.path.relative_to(REPO_ROOT)}/ -> {args.host}:{stack_dir}/")

        # 3. .env
        if args.init_env:
            ok, _ = remote_env(remote, "init", stack_dir)
            if not ok:
                return 1
        ok, tls_mode = remote_env(remote, "check", stack_dir)
        if not ok:
            print("[error] Fix the remote .env (see .env.example) and re-run.", file=sys.stderr)
            return 1

        # 4. App repo
        app_sha = ""
        if stack.app_repo:
            app_dir = f"{stack_dir}/{stack.app_repo.get('path', 'app')}"
            result = remote.run(
                f"if [ ! -d {shlex.quote(app_dir)}/.git ]; then git clone --quiet --depth 1 "
                f"{shlex.quote(stack.app_repo['url'])} {shlex.quote(app_dir)}; fi\n"
                f"git -C {shlex.quote(app_dir)} fetch --quiet --depth 1 origin {shlex.quote(app_ref)}\n"
                f"git -C {shlex.quote(app_dir)} checkout --quiet --force --detach FETCH_HEAD\n"
                f"git -C {shlex.quote(app_dir)} rev-parse HEAD",
                capture=True,
                describe=f"clone/fetch {stack.app_repo['url']}@{app_ref} into {app_dir}",
            )
            if result.returncode != 0:
                print(f"[error] Could not check out {app_ref}: {result.stderr.strip()}", file=sys.stderr)
                return 1
            app_sha = (result.stdout or "").strip().splitlines()[-1] if result.stdout else app_ref
            print(f"[ok] App repo at {app_sha or app_ref}")

        # 5. Build + up
        print(f"[deploy] Building and starting {stack.name} on {args.host} ...")
        result = remote.run(build_up_script(stack, stack_dir, args.skip_build), describe="compose pull/build/up --wait + prune")
        if result.returncode != 0:
            print(f"[error] docker compose up failed ({result.returncode}); inspect with: "
                  f"ssh {args.host} 'cd {stack_dir} && docker compose ps && docker compose logs --tail 100'",
                  file=sys.stderr)
            return 1

        # 6. Health check against the VM itself
        insecure = tls_mode == "internal"
        if args.dry_run:
            print(f"[dry-run] Would GET https://{stack.domain}{stack.health_path} via the VM IP "
                  f"(SNI {stack.domain}; certificate check skipped only if CADDY_TLS=internal)")
            connect_ip = args.connect_ip or "<vm-ip>"
        else:
            connect_ip = args.connect_ip or remote.resolve_ip()
            if insecure:
                print("[warn] CADDY_TLS=internal on the VM: skipping certificate verification (rehearsal mode)")
            if not args.skip_health_check and not https_check(connect_ip, stack.domain, stack.health_path, insecure):
                return 1

        # 7. Post-deploy seed/verification
        if stack.post_deploy and not args.skip_seed:
            seed_cmd = [
                sys.executable, str(SCRIPT_DIR / stack.post_deploy["script"]),
                stack.post_deploy.get("url_flag", "--url"), f"https://{stack.domain}",
                "--connect-ip", connect_ip,
            ]
            if insecure:
                seed_cmd.append("--insecure")
            if args.dry_run:
                seed_cmd.append("--dry-run")
            print(f"[deploy] Post-deploy: {shlex.join(seed_cmd)}")
            if subprocess.run(seed_cmd, check=False).returncode != 0:
                print("[error] Post-deploy seed/verification failed", file=sys.stderr)
                return 1

        # 8. Marker (no secrets)
        marker = json.dumps({
            "stack": stack.name,
            "infra_sha": local_git_sha(),
            "app_ref": app_ref,
            "app_sha": app_sha,
            "deployed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "actor": os.environ.get("GITHUB_ACTOR") or os.environ.get("USER", "unknown"),
            "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        })
        remote.run(f"cat > {shlex.quote(stack_dir)}/.deployed", input_text=marker + "\n", describe="write .deployed marker")
        print(f"[{'dry-run' if args.dry_run else 'ok'}] {stack.name} {'deploy preview complete for' if args.dry_run else 'deployed to'} {args.host}")
        return 0
    finally:
        remote.close()


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)  # keep our lines ordered with child process output
    parser = argparse.ArgumentParser(description="Deploy a cloud/<stack> docker compose stack to a VM over SSH.")
    parser.add_argument("--stack", required=True, choices=available_stacks(), help="Stack directory under cloud/")
    parser.add_argument(
        "--host",
        default=os.environ.get("DEPLOY_HOST_TARGET") or (
            f"{os.environ.get('DEPLOY_USER', 'deploy')}@{os.environ['DEPLOY_HOST']}" if os.environ.get("DEPLOY_HOST") else None
        ),
        help="SSH target (user@host or ~/.ssh/config alias). Defaults to $DEPLOY_USER@$DEPLOY_HOST.",
    )
    parser.add_argument("--app-ref", default=os.environ.get("APP_REF", ""), help="App repo ref/SHA (default: stack.json default_ref or $APP_REF)")
    parser.add_argument("--remote-root", default=os.environ.get("DEPLOY_REMOTE_ROOT", DEFAULT_REMOTE_ROOT), help=f"Remote stacks root (default: {DEFAULT_REMOTE_ROOT})")
    parser.add_argument("--identity-file", type=Path, default=Path(os.environ["DEPLOY_SSH_IDENTITY"]).expanduser() if os.environ.get("DEPLOY_SSH_IDENTITY") else None, help="SSH private key (default: ssh-agent / $DEPLOY_SSH_IDENTITY)")
    parser.add_argument("--connect-ip", default=os.environ.get("DEPLOY_CONNECT_IP", ""), help="IP for the HTTPS check (default: resolved from --host)")
    parser.add_argument("--init-env", action="store_true", help="Create the remote .env from .env.example if missing (secrets generated on the VM)")
    parser.add_argument("--skip-build", action="store_true", help="Skip `docker compose build` (restart with existing images)")
    parser.add_argument("--skip-health-check", action="store_true", help="Skip the HTTPS health check")
    parser.add_argument("--skip-seed", action="store_true", help="Skip the post-deploy seed/verification script")
    parser.add_argument("--dry-run", action="store_true", help="Print every command without connecting anywhere")
    args = parser.parse_args()
    if not args.host:
        parser.error("--host is required (or set DEPLOY_HOST)")
    sys.exit(deploy(args))


if __name__ == "__main__":
    main()
