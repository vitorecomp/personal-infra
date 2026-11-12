#!/usr/bin/env python3
"""Backs up one docker compose stack on its VM: database dump + volumes -> restic (GCS bucket).

Runs ON THE VM (shipped to /opt/stacks/.ops/ by deploy_stack.py, scheduled daily by the
stack-backup@<stack>.timer unit that bootstrap_vm.py installs). Standalone, stdlib only.

1. Dumps the stack database through `docker compose exec` (mysqldump --single-transaction or
   pg_dump -Fc). Passwords are read from the container's own env, never put on argv.
   The last --keep-local dumps stay in /var/backups/stacks/<stack>/ for fast restores.
2. Runs restic in a pinned container over: the dump directory, every volume in stack.json
   `backup.volumes`, and the stack .env (restic encrypts everything client-side).
3. Applies retention (7 daily / 4 weekly / 6 monthly) and runs `restic check` on Sundays.
4. Optionally pings $BACKUP_PING_URL on success.

Repository credentials come from the stack .env (RESTIC_REPOSITORY, RESTIC_PASSWORD,
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION) and are passed to the restic
container through the process environment (`-e NAME`), never on the command line.

Other modes: --init (create the repository if missing), --restore-test (restore the newest
snapshot to a temp dir and validate the dump), --snapshots (list), --dry-run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import os
import shlex
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

RESTIC_IMAGE = "restic/restic:0.19.1"
DEFAULT_STACKS_ROOT = Path("/opt/stacks")
DEFAULT_BACKUP_ROOT = Path("/var/backups/stacks")
RESTIC_ENV_KEYS = ("RESTIC_REPOSITORY", "RESTIC_PASSWORD", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_DEFAULT_REGION")
REQUIRED_KEYS = ("RESTIC_REPOSITORY", "RESTIC_PASSWORD", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")
RETENTION = ("--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6")
PLACEHOLDERS = ("", "__generate__", "__required__")


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


class Backup:
    def __init__(self, stack_dir: Path, backup_root: Path, dry_run: bool) -> None:
        self.stack_dir = stack_dir
        self.dry_run = dry_run
        self.meta = json.loads((stack_dir / "stack.json").read_text())
        self.name: str = self.meta["name"]
        self.dump_dir = backup_root / self.name
        env_file = stack_dir / ".env"
        if not env_file.exists() and dry_run:
            env_file = stack_dir / ".env.example"
        self.env_file = env_file
        self.env = parse_env(env_file) if env_file.exists() else {}
        self.compose = ["docker", "compose", "-p", self.name, "-f", str(stack_dir / "compose.yml")]

    # -- helpers --------------------------------------------------------
    def say_cmd(self, cmd: list[str]) -> None:
        print(f"[dry-run] Would run: {shlex.join(cmd)}")

    def restic_env(self) -> dict[str, str]:
        env = dict(os.environ)
        for key in RESTIC_ENV_KEYS:
            if self.env.get(key):
                env[key] = self.env[key]
        return env

    def check_credentials(self) -> bool:
        missing = [k for k in REQUIRED_KEYS if self.env.get(k, "") in PLACEHOLDERS]
        if missing and not self.dry_run:
            print(f"[error] {self.env_file} lacks restic settings: {', '.join(missing)}", file=sys.stderr)
            return False
        return True

    def restic(self, args: list[str], extra_mounts: list[str] | None = None, capture: bool = False) -> subprocess.CompletedProcess[str]:
        cmd = ["docker", "run", "--rm", "--hostname", self.name]
        for key in RESTIC_ENV_KEYS:
            cmd += ["-e", key]  # values come from the process environment, not argv
        cmd += ["-v", f"restic-cache-{self.name}:/root/.cache/restic"]
        for mount in extra_mounts or []:
            cmd += ["-v", mount]
        cmd += [RESTIC_IMAGE, *args]
        if self.dry_run:
            self.say_cmd(cmd)
            return subprocess.CompletedProcess(cmd, 0, "", "")
        return subprocess.run(cmd, env=self.restic_env(), text=True, capture_output=capture, check=False)

    # -- steps ----------------------------------------------------------
    def dump_database(self) -> Path | None:
        db = self.meta.get("backup", {}).get("db")
        if not db:
            print("[skip] stack.json has no backup.db section")
            return None
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        engine, service = db["engine"], db["service"]
        if engine == "mysql":
            target = self.dump_dir / f"{self.name}-db-{stamp}.sql.gz"
            inner = ('MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --quick '
                     '--no-tablespaces --routines --triggers --set-gtid-purged=OFF '
                     '--default-character-set=utf8mb4 "$MYSQL_DATABASE"')
            cmd = [*self.compose, "exec", "-T", service, "sh", "-c", inner]
        elif engine == "postgres":
            target = self.dump_dir / f"{self.name}-db-{stamp}.dump"
            cmd = [*self.compose, "exec", "-T", service, "sh", "-c",
                   'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc']
        else:
            print(f"[error] unsupported db engine {engine!r}", file=sys.stderr)
            return None

        if self.dry_run:
            self.say_cmd(cmd)
            print(f"[dry-run] Would write {target} (mode 0600)")
            return target

        self.dump_dir.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".partial")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as raw:
            sink = gzip.GzipFile(fileobj=raw, mode="wb") if engine == "mysql" else raw
            proc = subprocess.Popen(cmd, cwd=self.stack_dir, stdout=subprocess.PIPE)
            assert proc.stdout is not None
            for chunk in iter(lambda: proc.stdout.read(1 << 20), b""):
                sink.write(chunk)
            if sink is not raw:
                sink.close()
            rc = proc.wait()
        if rc != 0 or tmp.stat().st_size == 0:
            tmp.unlink(missing_ok=True)
            print(f"[error] database dump failed (exit {rc})", file=sys.stderr)
            return None
        os.replace(tmp, target)
        print(f"[ok] Dumped {engine} database -> {target} ({target.stat().st_size} bytes)")
        return target

    def prune_local(self, keep: int) -> None:
        dumps = sorted(self.dump_dir.glob(f"{self.name}-db-*"), key=lambda p: p.name, reverse=True)
        for old in dumps[keep:]:
            if self.dry_run:
                print(f"[dry-run] Would delete old local dump {old}")
            else:
                old.unlink()
                print(f"[ok] Removed old local dump {old.name}")

    def mounts(self) -> list[str]:
        mounts = [f"{self.dump_dir}:/backup/dumps:ro"]
        for volume in self.meta.get("backup", {}).get("volumes", []):
            mounts.append(f"{volume}:/backup/volumes/{volume}:ro")
        env_file = self.stack_dir / ".env"
        if env_file.exists() or self.dry_run:
            mounts.append(f"{env_file}:/backup/env/.env:ro")
        return mounts

    def init_repo(self) -> bool:
        if not self.check_credentials():
            return False
        probe = self.restic(["cat", "config"], capture=True)
        if probe.returncode == 0 and not self.dry_run:
            print(f"[ok] restic repository already initialised: {self.env.get('RESTIC_REPOSITORY')}")
            return True
        result = self.restic(["init"])
        if result.returncode != 0:
            print("[error] restic init failed", file=sys.stderr)
            return False
        print(f"[ok] restic repository ready: {self.env.get('RESTIC_REPOSITORY', '<from .env>')}")
        return True

    def backup(self, keep_local: int) -> bool:
        if not self.check_credentials():
            return False
        if self.dump_database() is None and self.meta.get("backup", {}).get("db"):
            return False
        self.prune_local(keep_local)
        result = self.restic(["backup", "/backup", "--tag", self.name, "--host", self.name], self.mounts())
        if result.returncode != 0:
            print("[error] restic backup failed (run with --init if the repository is new)", file=sys.stderr)
            return False
        result = self.restic(["forget", "--tag", self.name, "--host", self.name, *RETENTION, "--prune"])
        if result.returncode != 0:
            print("[error] restic forget/prune failed", file=sys.stderr)
            return False
        if dt.datetime.now(dt.timezone.utc).weekday() == 6:
            if self.restic(["check"]).returncode != 0:
                print("[error] restic check reported problems", file=sys.stderr)
                return False
        self.ping()
        print(f"[ok] Backup of {self.name} complete")
        return True

    def restore_test(self) -> bool:
        if not self.check_credentials():
            return False
        if self.dry_run:
            self.restic(["restore", "latest", "--tag", self.name, "--target", "/restore", "--include", "/backup/dumps"],
                        ["<tmpdir>:/restore"])
            return True
        with tempfile.TemporaryDirectory(prefix=f"restore-{self.name}-") as tmp:
            os.chmod(tmp, 0o700)
            result = self.restic(
                ["restore", "latest", "--tag", self.name, "--target", "/restore", "--include", "/backup/dumps"],
                [f"{tmp}:/restore"],
            )
            if result.returncode != 0:
                print("[error] restic restore failed", file=sys.stderr)
                return False
            dumps = sorted(Path(tmp).rglob(f"{self.name}-db-*"), key=lambda p: p.name)
            if not dumps:
                print("[error] restored snapshot contains no database dump", file=sys.stderr)
                return False
            newest = dumps[-1]
            newest_name, newest_size = newest.name, newest.stat().st_size
            try:
                if newest.suffix == ".gz":
                    with gzip.open(newest, "rb") as fh:
                        head = fh.read(4096)
                        while fh.read(1 << 20):
                            pass
                    valid = b"MySQL dump" in head or b"-- MySQL" in head or b"mysqldump" in head
                else:
                    with open(newest, "rb") as fh:
                        valid = fh.read(5) == b"PGDMP"
            except OSError as err:
                print(f"[error] could not read restored dump: {err}", file=sys.stderr)
                return False
            # Restored files are owned by root (restic container); clean them via a container too.
            subprocess.run(["docker", "run", "--rm", "-v", f"{tmp}:/restore", "alpine:3.24.4", "rm", "-rf", "/restore/backup"],
                           check=False, capture_output=True)
            if not valid:
                print(f"[error] restored dump {newest_name} failed validation", file=sys.stderr)
                return False
            print(f"[ok] Restore test passed: {newest_name} ({newest_size} bytes) is a valid dump")
            return True

    def snapshots(self) -> bool:
        return self.restic(["snapshots", "--tag", self.name]).returncode == 0

    def ping(self) -> None:
        url = self.env.get("BACKUP_PING_URL", "")
        if not url:
            return
        try:
            urllib.request.urlopen(url, timeout=10).read()
            print("[ok] Pinged BACKUP_PING_URL")
        except OSError as err:
            print(f"[warn] BACKUP_PING_URL ping failed: {err}")


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description="Back up a compose stack (db dump + volumes) with restic.")
    parser.add_argument("--stack", default="", help="Stack name under --stacks-root (e.g. personal-blog)")
    parser.add_argument("--stacks-root", type=Path, default=Path(os.environ.get("STACKS_ROOT", DEFAULT_STACKS_ROOT)), help=f"Stacks root on the VM (default: {DEFAULT_STACKS_ROOT})")
    parser.add_argument("--stack-dir", type=Path, help="Explicit stack directory (overrides --stack/--stacks-root; used by CI dry-runs)")
    parser.add_argument("--backup-root", type=Path, default=Path(os.environ.get("BACKUP_ROOT", DEFAULT_BACKUP_ROOT)), help=f"Local dump directory root (default: {DEFAULT_BACKUP_ROOT})")
    parser.add_argument("--keep-local", type=int, default=7, help="Local dumps to keep (default: 7)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--init", action="store_true", help="Initialise the restic repository if it does not exist")
    group.add_argument("--restore-test", action="store_true", help="Restore the newest snapshot to a temp dir and validate the dump")
    group.add_argument("--snapshots", action="store_true", help="List snapshots for this stack")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without running docker/restic")
    args = parser.parse_args()

    stack_dir = args.stack_dir.expanduser().resolve() if args.stack_dir else (args.stacks_root / args.stack if args.stack else None)
    if stack_dir is None or not (stack_dir / "stack.json").is_file():
        parser.error("pass --stack <name> (with /opt/stacks/<name>/stack.json) or --stack-dir <dir>")

    job = Backup(stack_dir, args.backup_root, args.dry_run)
    if args.init:
        ok = job.init_repo()
    elif args.restore_test:
        ok = job.restore_test()
    elif args.snapshots:
        ok = job.snapshots()
    else:
        ok = job.backup(args.keep_local)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
