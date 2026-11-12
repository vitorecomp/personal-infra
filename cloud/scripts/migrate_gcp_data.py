#!/usr/bin/env python3
"""TEMPORARY: moves Ghost/Taiga data from GCP (Cloud SQL + GCS, project compute-bench) to the new VMs.

Delete this script once the old GCP stack is decommissioned (Phase 5 of
documentation/migration-runbook.md).

Subcommands (all support --dry-run):
  archive        Server-side `gcloud sql export sql` into a GCS archive bucket + download it, and
                 copy the content bucket locally. Needs no VM (baseline / final archive).
  export         Dump Cloud SQL straight onto the VM: cloud-sql-proxy runs locally, an SSH reverse
                 tunnel exposes it on the VM's loopback, and the dump client runs in a container on
                 the VM (no local Docker or DB client needed). Content bucket is synced to the VM.
                 A copy of everything is pulled back into the local workdir.
  import         Stop the app, DROP + recreate the database, restore the newest export, replace the
                 content volume, start the app. Requires --confirm-overwrite. Re-running converges,
                 so the final pre-cutover sync is simply `all` again.
  verify         Exact row counts (source vs target) on key tables + file counts/bytes + HTTPS smoke.
  all            export + import + verify.
  copy-secrets   (taiga) Copy TAIGA_SECRET_KEY / TAIGA_ADMIN_* from the Cloud Run env into the VM .env
                 through SSH stdin. Run BEFORE Taiga's first boot on the VM.

Secrets (DB passwords, Taiga secret key) are read from `gcloud run services describe` into memory
and only ever travel over SSH stdin; they are never printed or put on a command line.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from deploy_stack import Remote, https_check, load_stack  # noqa: E402

GCP_PROJECT = "compute-bench"
GCP_REGION = "us-central1"
DEFAULT_WORKDIR = Path("~/.local/state/personal-infra/migrations").expanduser()
DEFAULT_ARCHIVE_BUCKET = os.environ.get("MIGRATION_ARCHIVE_BUCKET", "compute-bench_cloudbuild")
REMOTE_ROOT = "/opt/stacks"
MYSQL_CLIENT_IMAGE = "mysql:8.0.46"
POSTGRES_CLIENT_IMAGE = "postgres:15.19-alpine"
ALPINE_IMAGE = "alpine:3.24.4"


@dataclass(frozen=True)
class Source:
    stack: str
    engine: str
    instance: str
    database: str
    user: str
    run_service: str
    password_env: str
    bucket: str
    content_subdirs: tuple[str, ...]
    volume: str
    volume_owner: str | None
    app_service: str
    db_service: str
    proxy_port: int
    tables: tuple[str, ...]
    secret_envs: tuple[str, ...] = field(default_factory=tuple)

    @property
    def connection_name(self) -> str:
        return f"{GCP_PROJECT}:{GCP_REGION}:{self.instance}"

    @property
    def dump_name(self) -> str:
        return "db.sql.gz" if self.engine == "mysql" else "db.dump"


SOURCES: dict[str, Source] = {
    "personal-blog": Source(
        stack="personal-blog",
        engine="mysql",
        instance="personal-blog-mysql",
        database="ghost",
        user="ghost",
        run_service="personal-blog",
        password_env="database__connection__password",
        bucket="blog-content-compute-bench",
        content_subdirs=("images", "files", "settings"),
        volume="personal-blog_ghost-content",
        volume_owner="1000:1000",  # node user in ghost:*-alpine
        app_service="ghost",
        db_service="db",
        proxy_port=3307,
        tables=("posts", "users", "tags", "posts_tags", "settings", "members", "api_keys", "integrations", "newsletters"),
    ),
    "taiga": Source(
        stack="taiga",
        engine="postgres",
        instance="taiga-postgres",
        database="taiga",
        user="taiga",
        run_service="taiga",
        password_env="POSTGRES_PASSWORD",
        bucket="taiga-content-compute-bench",
        content_subdirs=("media",),
        volume="taiga_media",
        volume_owner=None,  # Taiga container runs as root
        app_service="taiga",
        db_service="db",
        proxy_port=5433,
        tables=(
            "users_user", "projects_project", "projects_membership", "milestones_milestone",
            "userstories_userstory", "tasks_task", "issues_issue", "epics_epic",
            "wiki_wikipage", "attachments_attachment", "history_historyentry",
        ),
        secret_envs=("TAIGA_SECRET_KEY", "TAIGA_ADMIN_USER", "TAIGA_ADMIN_EMAIL", "TAIGA_ADMIN_PASSWORD"),
    ),
}


# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------


def run(cmd: list[str], dry_run: bool, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
    if dry_run:
        print(f"[dry-run] Would run: {shlex.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0, "", "")
    result = subprocess.run(cmd, text=True, capture_output=capture, check=False)
    if check and result.returncode != 0:
        detail = (result.stderr or "").strip()
        raise SystemExit(f"[error] {shlex.join(cmd)} failed ({result.returncode}) {detail}")
    return result


def cloud_run_env(src: Source, dry_run: bool) -> dict[str, str]:
    """Reads the Cloud Run service env into memory (values are never printed)."""
    if dry_run:
        print(f"[dry-run] Would read env of Cloud Run service {src.run_service} ({GCP_PROJECT}/{GCP_REGION})")
        return {src.password_env: "dry-run", **{k: "dry-run" for k in src.secret_envs}}
    result = run(
        ["gcloud", "run", "services", "describe", src.run_service, "--project", GCP_PROJECT,
         "--region", GCP_REGION, "--format=json"],
        dry_run=False, capture=True,
    )
    container = json.loads(result.stdout)["spec"]["template"]["spec"]["containers"][0]
    return {e["name"]: e.get("value", "") for e in container.get("env", [])}


def proxy_command(src: Source) -> list[str]:
    binary = shutil.which("cloud-sql-proxy")
    base = [binary] if binary else ["mise", "exec", "--", "cloud-sql-proxy"]
    return [*base, "--gcloud-auth", "--address", "127.0.0.1", "--port", str(src.proxy_port), src.connection_name]


class Proxy:
    """Runs cloud-sql-proxy locally for the duration of a with-block."""

    def __init__(self, src: Source, dry_run: bool) -> None:
        self.src = src
        self.dry_run = dry_run
        self.proc: subprocess.Popen[bytes] | None = None

    def __enter__(self) -> "Proxy":
        cmd = proxy_command(self.src)
        if self.dry_run:
            print(f"[dry-run] Would start: {shlex.join(cmd)}")
            return self
        print(f"[proxy] {shlex.join(cmd)}")
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(60):
            if self.proc.poll() is not None:
                err = self.proc.stderr.read().decode() if self.proc.stderr else ""
                raise SystemExit(f"[error] cloud-sql-proxy exited early: {err.strip()}")
            try:
                with socket.create_connection(("127.0.0.1", self.src.proxy_port), timeout=1):
                    print(f"[ok] cloud-sql-proxy listening on 127.0.0.1:{self.src.proxy_port}")
                    return self
            except OSError:
                time.sleep(1)
        raise SystemExit("[error] cloud-sql-proxy did not start listening within 60s")

    def __exit__(self, *_exc: object) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def tunnel_run(remote: Remote, src: Source, script: str, secret: str, describe: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    """Runs `script` on the VM with the local proxy port reverse-forwarded to the VM loopback.

    The first line of stdin is the source DB password; scripts read it with `IFS= read -r`.
    """
    port = src.proxy_port
    # A dedicated (non-multiplexed) connection: forwards requested through a ControlMaster would
    # outlive this command and make the next tunnel fail with "port already in use".
    opts: list[str] = []
    skip_next = False
    for i, opt in enumerate(remote.ssh_opts):
        if skip_next:
            skip_next = False
            continue
        if opt == "-o" and remote.ssh_opts[i + 1].startswith(("ControlMaster=", "ControlPath=", "ControlPersist=")):
            skip_next = True
            continue
        opts.append(opt)
    cmd = [
        "ssh", *opts,
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "ExitOnForwardFailure=yes",
        "-R", f"127.0.0.1:{port}:127.0.0.1:{port}",
        remote.host,
        "bash -c " + shlex.quote("set -euo pipefail\n" + script),
    ]
    if remote.dry_run:
        print(f"[dry-run] Would run on {remote.host} via reverse tunnel :{port}: {describe}")
        return subprocess.CompletedProcess(cmd, 0, "", "")
    return subprocess.run(cmd, input=secret + "\n", text=True, capture_output=capture, check=False)


def count_query(src: Source) -> str:
    if src.engine == "mysql":
        return " UNION ALL ".join(f"SELECT '{t}', COUNT(*) FROM `{t}`" for t in src.tables)
    return " UNION ALL ".join(f"SELECT '{t}', COUNT(*) FROM \"{t}\"" for t in src.tables)


def parse_counts(output: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in output.splitlines():
        parts = line.strip().split("\t")
        if len(parts) == 2 and parts[1].isdigit():
            counts[parts[0]] = int(parts[1])
    return counts


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_archive(src: Source, args: argparse.Namespace) -> int:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    workdir = args.workdir / src.stack / f"archive-{stamp}"
    ext = "sql.gz"
    gcs_uri = f"gs://{args.archive_bucket}/sql-archive/{src.stack}/{stamp}.{ext}"
    if not args.dry_run:
        workdir.mkdir(parents=True, mode=0o700)
    sa = "dry-run-sa"
    if not args.dry_run:
        sa = run(["gcloud", "sql", "instances", "describe", src.instance, "--project", GCP_PROJECT,
                  "--format=value(serviceAccountEmailAddress)"], dry_run=False, capture=True).stdout.strip()
    run(["gcloud", "storage", "buckets", "add-iam-policy-binding", f"gs://{args.archive_bucket}",
         f"--member=serviceAccount:{sa}", "--role=roles/storage.objectAdmin", "--quiet"],
        args.dry_run, capture=True)
    run(["gcloud", "sql", "export", "sql", src.instance, gcs_uri, "--project", GCP_PROJECT,
         f"--database={src.database}", "--quiet"], args.dry_run)
    run(["gcloud", "storage", "cp", gcs_uri, str(workdir / f"{src.database}.{ext}")], args.dry_run)
    run(["gcloud", "storage", "rsync", "--recursive", f"gs://{src.bucket}", str(workdir / "content")], args.dry_run)
    if args.dry_run:
        return 0
    manifest = {
        "stack": src.stack,
        "created_at": stamp,
        "gcs_export": gcs_uri,
        "sha256": {p.name: sha256(p) for p in workdir.glob(f"*.{ext}")},
        "content_files": sum(1 for p in (workdir / "content").rglob("*") if p.is_file()),
    }
    (workdir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[ok] Archived {src.stack} to {workdir} (and {gcs_uri})")
    return 0


def remote_migration_dir(src: Source, stamp: str) -> str:
    return f"{REMOTE_ROOT}/{src.stack}/.migration/{stamp}"


def cmd_export(src: Source, args: argparse.Namespace, remote: Remote) -> tuple[int, str]:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    rdir = remote_migration_dir(src, stamp)
    local = args.workdir / src.stack / f"export-{stamp}"
    if not args.dry_run:
        local.mkdir(parents=True, mode=0o700)
    env = cloud_run_env(src, args.dry_run)
    password = env.get(src.password_env, "")
    if not password:
        print(f"[error] {src.password_env} not found in Cloud Run service {src.run_service}", file=sys.stderr)
        return 1, ""

    port = src.proxy_port
    if src.engine == "mysql":
        dump = (f"docker run --rm -i --network host {MYSQL_CLIENT_IMAGE} sh -c "
                + shlex.quote(f'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysqldump -h127.0.0.1 -P{port} '
                              f'-u{src.user} --single-transaction --quick --no-tablespaces --set-gtid-purged=OFF '
                              f'--routines --triggers --default-character-set=utf8mb4 {src.database}')
                + f" | gzip > {rdir}/{src.dump_name}")
    else:
        dump = (f"docker run --rm -i --network host {POSTGRES_CLIENT_IMAGE} sh -c "
                + shlex.quote(f'IFS= read -r PGPASSWORD; export PGPASSWORD; exec pg_dump -h 127.0.0.1 -p {port} '
                              f'-U {src.user} -d {src.database} -Fc --no-owner --no-acl')
                + f" > {rdir}/{src.dump_name}")
    script = f"umask 077\nmkdir -p {rdir}/content\n{dump}\ntest -s {rdir}/{src.dump_name}\nls -l {rdir}/{src.dump_name}"

    with Proxy(src, args.dry_run):
        result = tunnel_run(remote, src, script, password, f"dump {src.engine} {src.database} -> {rdir}/{src.dump_name}")
        if result.returncode != 0:
            print("[error] remote dump failed", file=sys.stderr)
            return 1, ""
        source_counts = source_row_counts(src, remote, password)

    # Content bucket -> local -> VM
    run(["gcloud", "storage", "rsync", "--recursive", "--delete-unmatched-destination-objects",
         f"gs://{src.bucket}", str(local / "content")], args.dry_run)
    if not remote.rsync(f"{local}/content/", f"{rdir}/content/"):
        return 1, ""
    # Pull the dump back for the local archive
    pull = ["rsync", "-a", "-e", shlex.join(["ssh", *remote.ssh_opts]), f"{remote.host}:{rdir}/{src.dump_name}", f"{local}/"]
    run(pull, args.dry_run)
    if not args.dry_run:
        manifest = {
            "stack": src.stack,
            "exported_at": stamp,
            "remote_dir": rdir,
            "dump_sha256": sha256(local / src.dump_name),
            "source_row_counts": source_counts,
            "content_files": sum(1 for p in (local / "content").rglob("*") if p.is_file()),
        }
        (local / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        remote.run(f"cat > {rdir}/manifest.json", input_text=json.dumps(manifest, indent=2) + "\n", describe="write manifest")
    print(f"[ok] Exported {src.stack} -> {remote.host}:{rdir} (local copy {local})")
    return 0, rdir


def source_row_counts(src: Source, remote: Remote, password: str) -> dict[str, int]:
    port = src.proxy_port
    query = count_query(src)
    if src.engine == "mysql":
        inner = (f'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysql -h127.0.0.1 -P{port} -u{src.user} '
                 f'-N -B {src.database} -e {shlex.quote(query)}')
        script = f"docker run --rm -i --network host {MYSQL_CLIENT_IMAGE} sh -c {shlex.quote(inner)}"
    else:
        inner = (f'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -h 127.0.0.1 -p {port} -U {src.user} '
                 f'-d {src.database} -At -F "$(printf \'\\t\')" -c {shlex.quote(query)}')
        script = f"docker run --rm -i --network host {POSTGRES_CLIENT_IMAGE} sh -c {shlex.quote(inner)}"
    result = tunnel_run(remote, src, script, password, "count source rows", capture=True)
    if remote.dry_run:
        return {}
    if result.returncode != 0:
        print(f"[warn] could not count source rows: {result.stderr.strip()}")
        return {}
    return parse_counts(result.stdout)


def target_row_counts(src: Source, remote: Remote) -> dict[str, int]:
    query = count_query(src)
    compose = f"cd {REMOTE_ROOT}/{src.stack} && docker compose -p {src.stack} -f compose.yml exec -T {src.db_service}"
    if src.engine == "mysql":
        inner = f'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -B {src.database} -e {shlex.quote(query)}'
    else:
        inner = f'exec psql -U "$POSTGRES_USER" -d {src.database} -At -F "$(printf \'\\t\')" -c {shlex.quote(query)}'
    result = remote.run(f"{compose} sh -c {shlex.quote(inner)}", capture=True, describe="count target rows")
    if remote.dry_run:
        return {}
    if result.returncode != 0:
        print(f"[warn] could not count target rows: {result.stderr.strip()}")
        return {}
    return parse_counts(result.stdout)


def latest_remote_dir(src: Source, remote: Remote) -> str:
    base = f"{REMOTE_ROOT}/{src.stack}/.migration"
    result = remote.run(f"ls -1d {base}/*/ 2>/dev/null | sort | tail -n 1", capture=True, describe=f"find newest export in {base}")
    if remote.dry_run:
        return f"{base}/<newest>"
    path = (result.stdout or "").strip().rstrip("/")
    if not path:
        raise SystemExit(f"[error] no export found under {base}; run `export` first")
    return path


def cmd_import(src: Source, args: argparse.Namespace, remote: Remote, rdir: str | None) -> int:
    if not args.confirm_overwrite:
        print("[error] import DROPS and recreates the VM database and content volume; pass --confirm-overwrite", file=sys.stderr)
        return 1
    rdir = rdir or latest_remote_dir(src, remote)
    stack_dir = f"{REMOTE_ROOT}/{src.stack}"
    compose = f"docker compose -p {src.stack} -f compose.yml"
    if src.engine == "mysql":
        reset_sql = (f"DROP DATABASE IF EXISTS `{src.database}`; "
                     f"CREATE DATABASE `{src.database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci; "
                     f"GRANT ALL PRIVILEGES ON `{src.database}`.* TO '{src.user}'@'%'; FLUSH PRIVILEGES;")
        reset = f"{compose} exec -T {src.db_service} sh -c " + shlex.quote(
            f'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -e {shlex.quote(reset_sql)}')
        restore = f"gunzip -c {rdir}/{src.dump_name} | {compose} exec -T {src.db_service} sh -c " + shlex.quote(
            f'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot {src.database}')
    else:
        reset = f"{compose} exec -T {src.db_service} sh -c " + shlex.quote(
            f'exec psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 '
            f'-c "DROP DATABASE IF EXISTS {src.database} WITH (FORCE);" '
            f'-c "CREATE DATABASE {src.database} OWNER $POSTGRES_USER;"')
        # pg_restore exits 1 on harmless warnings (e.g. plpgsql comments); verify catches real problems.
        restore = f"{compose} exec -T {src.db_service} sh -c " + shlex.quote(
            f'pg_restore -U "$POSTGRES_USER" -d {src.database} --no-owner --no-acl') + f" < {rdir}/{src.dump_name} || echo '[warn] pg_restore reported warnings'"

    copy_parts = []
    for sub in src.content_subdirs:
        copy_parts.append(f"rm -rf /dst/{sub}; if [ -d /src/{sub} ]; then cp -a /src/{sub} /dst/{sub}; fi")
    if src.volume_owner:
        copy_parts.append(f"chown -R {src.volume_owner} " + " ".join(f"/dst/{s}" for s in src.content_subdirs) + " 2>/dev/null || true")
    content = (f"docker run --rm -v {src.volume}:/dst -v {rdir}/content:/src:ro {ALPINE_IMAGE} sh -c "
               + shlex.quote("set -e; " + "; ".join(copy_parts)))

    script = "\n".join([
        f"cd {stack_dir}",
        f"test -s {rdir}/{src.dump_name}",
        f"echo '[import] stopping {src.app_service}'",
        f"{compose} stop {src.app_service}",
        f"{compose} up -d --wait {src.db_service}",
        f"echo '[import] recreating database {src.database}'",
        reset,
        f"echo '[import] restoring {src.dump_name}'",
        restore,
        f"echo '[import] replacing content volume {src.volume}'",
        content,
        f"echo '[import] starting stack'",
        f"{compose} up -d --wait --wait-timeout 900",
    ])
    result = remote.run(script, describe=f"stop app, recreate {src.database}, restore {rdir}, replace {src.volume}, start")
    if result.returncode != 0:
        print("[error] import failed; inspect the stack with docker compose logs", file=sys.stderr)
        return 1
    print(f"[ok] Imported {rdir} into {src.stack}")
    return 0


def cmd_verify(src: Source, args: argparse.Namespace, remote: Remote) -> int:
    env = cloud_run_env(src, args.dry_run)
    with Proxy(src, args.dry_run):
        source = source_row_counts(src, remote, env.get(src.password_env, ""))
    target = target_row_counts(src, remote)

    # Content: bucket vs volume
    bucket_files = 0
    if not args.dry_run:
        listing = run(["gcloud", "storage", "ls", "--recursive", f"gs://{src.bucket}/**"], False, capture=True, check=False).stdout
        bucket_files = sum(1 for line in listing.splitlines()
                           if line.startswith("gs://") and not line.endswith("/")
                           and any(f"/{sub}/" in line for sub in src.content_subdirs))
    paths = " ".join(f"/v/{s}" for s in src.content_subdirs)
    vol = remote.run(f"docker run --rm -v {src.volume}:/v:ro {ALPINE_IMAGE} sh -c "
                     + shlex.quote(f"find {paths} -type f 2>/dev/null | wc -l"), capture=True, describe=f"count files in {src.volume}")
    volume_files = int((vol.stdout or "0").strip() or 0) if not args.dry_run else 0

    if args.dry_run:
        print("[dry-run] Would compare row counts, file counts and run an HTTPS smoke test")
        return 0

    ok = True
    print(f"{'table':<28}{'source':>10}{'target':>10}")
    for table in src.tables:
        s, t = source.get(table), target.get(table)
        flag = "" if s == t and s is not None else "  <-- MISMATCH"
        ok &= flag == ""
        print(f"{table:<28}{str(s):>10}{str(t):>10}{flag}")
    files_flag = "" if bucket_files == volume_files else "  <-- MISMATCH"
    ok &= files_flag == ""
    print(f"{'files (' + ','.join(src.content_subdirs) + ')':<28}{bucket_files:>10}{volume_files:>10}{files_flag}")

    stack = load_stack(src.stack)
    tls = remote.run(f"grep -qx 'CADDY_TLS=internal' {REMOTE_ROOT}/{src.stack}/.env && echo internal || echo acme",
                     capture=True, describe="read CADDY_TLS mode")
    insecure = (tls.stdout or "").strip() == "internal"
    ok &= https_check(remote.resolve_ip(), stack.domain, stack.health_path, insecure=insecure, retries=5, delay=3)
    print("[ok] verify: parity confirmed" if ok else "[error] verify: differences found", file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


_SET_ENV = r'''
import os, sys
path, keys = sys.argv[1], sys.argv[2].split(",")
values = [sys.stdin.readline().rstrip("\n") for _ in keys]
lines = open(path).read().splitlines() if os.path.exists(path) else []
changed = []
for key, value in zip(keys, values):
    if not value:
        continue
    new = f"{key}={value}"
    idx = next((i for i, l in enumerate(lines) if l.split("=", 1)[0].strip() == key), None)
    if idx is None:
        lines.append(new); changed.append(key)
    elif lines[idx] != new:
        lines[idx] = new; changed.append(key)
fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(path + ".tmp", path)
print(f"[ok] .env updated: {', '.join(changed) if changed else 'already up to date'}")
'''


def cmd_copy_secrets(src: Source, args: argparse.Namespace, remote: Remote) -> int:
    if not src.secret_envs:
        print(f"[skip] {src.stack} has no secrets to copy from Cloud Run")
        return 0
    env = cloud_run_env(src, args.dry_run)
    missing = [k for k in src.secret_envs if not env.get(k)]
    if missing:
        print(f"[warn] not set on Cloud Run (left untouched): {', '.join(missing)}")
    stdin = "\n".join(env.get(k, "") for k in src.secret_envs) + "\n"
    env_path = f"{REMOTE_ROOT}/{src.stack}/.env"
    result = remote.run(
        f"test -f {env_path} || {{ echo '[error] {env_path} missing; run deploy_stack.py --init-env first' >&2; exit 3; }}\n"
        f"python3 -c {shlex.quote(_SET_ENV)} {env_path} {','.join(src.secret_envs)}",
        input_text=stdin,
        describe=f"set {', '.join(src.secret_envs)} in {env_path} (values via stdin)",
    )
    return 0 if result.returncode == 0 else 1


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description="TEMPORARY: migrate Ghost/Taiga data from GCP to the compose VMs.")
    parser.add_argument("command", choices=("archive", "export", "import", "verify", "all", "copy-secrets"))
    parser.add_argument("--stack", required=True, choices=sorted(SOURCES))
    parser.add_argument("--host", default=os.environ.get("MIGRATION_HOST", ""), help="VM SSH target, e.g. deploy@203.0.113.10 (not needed for archive)")
    parser.add_argument("--identity-file", type=Path, help="SSH private key for the deploy user")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR, help=f"Local artifact directory, outside the repo (default: {DEFAULT_WORKDIR})")
    parser.add_argument("--archive-bucket", default=DEFAULT_ARCHIVE_BUCKET, help=f"GCS bucket for `archive` exports (default: {DEFAULT_ARCHIVE_BUCKET})")
    parser.add_argument("--confirm-overwrite", action="store_true", help="Required by import/all: drop and replace VM data")
    parser.add_argument("--dry-run", action="store_true", help="Print every command without touching GCP or the VM")
    args = parser.parse_args()
    args.workdir = args.workdir.expanduser().resolve()
    src = SOURCES[args.stack]

    if args.command == "archive":
        sys.exit(cmd_archive(src, args))
    if not args.host:
        parser.error(f"--host is required for {args.command}")

    remote = Remote(args.host, args.identity_file.expanduser() if args.identity_file else None, args.dry_run)
    try:
        if args.command == "copy-secrets":
            sys.exit(cmd_copy_secrets(src, args, remote))
        if args.command == "export":
            sys.exit(cmd_export(src, args, remote)[0])
        if args.command == "import":
            sys.exit(cmd_import(src, args, remote, None))
        if args.command == "verify":
            sys.exit(cmd_verify(src, args, remote))
        if args.command == "all":
            if not args.confirm_overwrite:
                parser.error("all includes import; pass --confirm-overwrite")
            rc, rdir = cmd_export(src, args, remote)
            if rc == 0:
                rc = cmd_import(src, args, remote, rdir)
            if rc == 0:
                rc = cmd_verify(src, args, remote)
            sys.exit(rc)
    finally:
        remote.close()


if __name__ == "__main__":
    main()
