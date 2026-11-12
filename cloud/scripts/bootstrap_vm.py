#!/usr/bin/env python3
"""Idempotently bootstraps an Ubuntu VM (Oracle A1 or GCE) to host docker compose stacks.

Local mode (default): pipes THIS file over SSH and runs it as root on the VM
(`ssh <host> sudo python3 - --remote ...`), so the VM needs nothing but python3.

Converged state:
  * apt basics + Docker CE + compose/buildx plugins from Docker's apt repo (amd64/arm64)
  * /etc/docker/daemon.json: `local` log driver with rotation, live-restore; journald capped
  * swapfile + vm.swappiness=10
  * `deploy` user (docker group, no sudo, key-only) and /opt/stacks, /var/backups/stacks
  * sshd drop-in: no passwords, no root login (validated with `sshd -t` before reload)
  * unattended-upgrades with automatic reboot at a fixed time
  * Oracle only: host iptables ACCEPT for tcp/80,443 inserted before Canonical's REJECT rule
    (live + /etc/iptables/rules.v4). Never flushes rules or runs `netfilter-persistent save`.
  * stack-backup@.service/.timer units (run /opt/stacks/.ops/backup_stack.py daily)

Modes:
  --dry-run   print the SSH command and the step list, no connection
  --check     connect and report drift without changing anything (exit 2 on drift)
  (default)   apply
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

DEFAULT_DEPLOY_USER = "deploy"
DEFAULT_SWAP_GB = 2
DEFAULT_REBOOT_TIME = "04:30"
APT_BASICS = ("ca-certificates", "curl", "git", "rsync", "unattended-upgrades", "python3", "gnupg")
DOCKER_PACKAGES = ("docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin")
DAEMON_JSON = {
    "log-driver": "local",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "live-restore": True,
}
JOURNALD_CONF = "[Journal]\nSystemMaxUse=200M\n"
SSHD_DROPIN_PATH = "/etc/ssh/sshd_config.d/00-personal-infra.conf"  # sshd keeps the FIRST value; 00- beats 50-cloud-init
SSHD_DROPIN = (
    "# Managed by personal-infra cloud/scripts/bootstrap_vm.py\n"
    "PasswordAuthentication no\n"
    "KbdInteractiveAuthentication no\n"
    "PermitRootLogin no\n"
    "X11Forwarding no\n"
    "MaxAuthTries 4\n"
)
AUTO_UPGRADES = 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
BACKUP_SERVICE = """# Managed by personal-infra cloud/scripts/bootstrap_vm.py
[Unit]
Description=restic backup of the %i compose stack
Wants=network-online.target
After=network-online.target docker.service
ConditionPathExists=/opt/stacks/.ops/backup_stack.py
ConditionPathExists=/opt/stacks/%i/.env

[Service]
Type=oneshot
User={user}
ExecStart=/usr/bin/python3 /opt/stacks/.ops/backup_stack.py --stack %i
Nice=10
IOSchedulingClass=idle
"""
BACKUP_TIMER = """# Managed by personal-infra cloud/scripts/bootstrap_vm.py
[Unit]
Description=Daily restic backup of the %i compose stack

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
"""
WEB_PORTS = (80, 443)


# ===========================================================================
# Remote side (runs as root on the VM)
# ===========================================================================


class Converger:
    def __init__(self, check_only: bool) -> None:
        self.check_only = check_only
        self.drift: list[str] = []

    # -- helpers --------------------------------------------------------
    def sh(self, cmd: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["bash", "-c", cmd],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"},
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"command failed ({result.returncode}): {cmd}\n{result.stderr.strip()}")
        return result

    def ok(self, msg: str) -> None:
        print(f"[ok] {msg}")

    def change(self, msg: str) -> bool:
        """Records drift; returns True when the caller should apply the change."""
        if self.check_only:
            print(f"[drift] {msg}")
            self.drift.append(msg)
            return False
        print(f"[apply] {msg}")
        return True

    def ensure_file(self, path: str, content: str, mode: int = 0o644) -> bool:
        """Writes `content` if different. Returns True when the file changed."""
        p = Path(path)
        if p.exists() and p.read_text() == content:
            self.ok(f"{path} up to date")
            return False
        if self.change(f"write {path}"):
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_name(p.name + ".tmp")
            tmp.write_text(content)
            os.chmod(tmp, mode)
            os.replace(tmp, p)
            return True
        return False

    def installed(self, pkg: str) -> bool:
        r = self.sh(f"dpkg-query -W -f='${{Status}}' {shlex.quote(pkg)} 2>/dev/null", check=False)
        return "install ok installed" in r.stdout

    # -- steps ----------------------------------------------------------
    def assert_ubuntu(self) -> None:
        release = Path("/etc/os-release").read_text()
        if "ID=ubuntu" not in release:
            raise RuntimeError("only Ubuntu is supported")
        version = re.search(r'VERSION_ID="([^"]+)"', release)
        arch = self.sh("dpkg --print-architecture").stdout.strip()
        self.ok(f"Ubuntu {version.group(1) if version else '?'} ({arch})")

    def apt_basics(self) -> None:
        missing = [p for p in APT_BASICS if not self.installed(p)]
        if not missing:
            self.ok("base packages installed")
            return
        if self.change(f"apt install {' '.join(missing)}"):
            self.sh("apt-get update -qq")
            self.sh(f"apt-get install -y -qq {' '.join(missing)}")

    def docker(self) -> None:
        missing = [p for p in DOCKER_PACKAGES if not self.installed(p)]
        if not missing:
            self.ok("Docker CE + compose plugin installed")
        elif self.change(f"install Docker CE from download.docker.com ({', '.join(missing)})"):
            self.sh("install -m 0755 -d /etc/apt/keyrings")
            self.sh("curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc")
            self.sh("chmod a+r /etc/apt/keyrings/docker.asc")
            codename = self.sh(". /etc/os-release && echo \"${UBUNTU_CODENAME:-$VERSION_CODENAME}\"").stdout.strip()
            arch = self.sh("dpkg --print-architecture").stdout.strip()
            Path("/etc/apt/sources.list.d/docker.list").write_text(
                f"deb [arch={arch} signed-by=/etc/apt/keyrings/docker.asc] "
                f"https://download.docker.com/linux/ubuntu {codename} stable\n"
            )
            self.sh("apt-get update -qq")
            self.sh(f"apt-get install -y -qq {' '.join(DOCKER_PACKAGES)}")
        if self.installed("docker-ce"):
            active = self.sh("systemctl is-enabled docker && systemctl is-active docker", check=False)
            if active.returncode == 0:
                self.ok("docker.service enabled and active")
            elif self.change("enable + start docker.service"):
                self.sh("systemctl enable --now docker")

    def docker_daemon_config(self) -> None:
        content = json.dumps(DAEMON_JSON, indent=2) + "\n"
        if self.ensure_file("/etc/docker/daemon.json", content) and self.installed("docker-ce"):
            # live-restore keeps running containers up across this restart
            self.sh("systemctl restart docker")
        if self.ensure_file("/etc/systemd/journald.conf.d/00-personal-infra.conf", JOURNALD_CONF):
            self.sh("systemctl restart systemd-journald")

    def swap(self, size_gb: int) -> None:
        active = self.sh("swapon --show=NAME --noheadings", check=False).stdout.split()
        if "/swapfile" in active:
            self.ok("/swapfile active")
        elif active:
            self.ok(f"swap already active ({', '.join(active)}); not adding /swapfile")
        elif self.change(f"create and enable {size_gb}G /swapfile"):
            if not Path("/swapfile").exists():
                self.sh(f"fallocate -l {size_gb}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count={size_gb * 1024}")
            self.sh("chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile")
        fstab = Path("/etc/fstab").read_text()
        if "/swapfile" not in fstab and ("/swapfile" in active or not self.check_only):
            if self.change("persist /swapfile in /etc/fstab"):
                with open("/etc/fstab", "a") as fh:
                    fh.write("/swapfile none swap sw 0 0\n")
        if self.ensure_file("/etc/sysctl.d/99-personal-infra-swappiness.conf", "vm.swappiness=10\n"):
            self.sh("sysctl -q -p /etc/sysctl.d/99-personal-infra-swappiness.conf")

    def deploy_user(self, user: str, pubkey: str) -> None:
        if self.sh(f"id -u {user}", check=False).returncode == 0:
            self.ok(f"user {user} exists")
        elif self.change(f"create user {user}"):
            self.sh(f"useradd --create-home --shell /bin/bash {user}")
            # '*' = no password but NOT locked, so pubkey logins work with any PAM setup
            self.sh(f"usermod -p '*' {user}")
        if self.sh(f"id -u {user}", check=False).returncode == 0:
            groups = self.sh(f"id -nG {user}").stdout.split()
            if "docker" in groups:
                self.ok(f"{user} in docker group")
            elif self.sh("getent group docker", check=False).returncode == 0 and self.change(f"add {user} to docker group"):
                self.sh(f"usermod -aG docker {user}")
            home = Path(self.sh(f"getent passwd {user} | cut -d: -f6").stdout.strip())
            auth = home / ".ssh" / "authorized_keys"
            existing = auth.read_text() if auth.exists() else ""
            if pubkey.strip() in existing:
                self.ok(f"deploy key present in {auth}")
            elif self.change(f"add deploy key to {auth}"):
                auth.parent.mkdir(mode=0o700, exist_ok=True)
                with open(auth, "a") as fh:
                    fh.write(pubkey.strip() + "\n")
                self.sh(f"chown -R {user}:{user} {shlex.quote(str(auth.parent))} && chmod 700 {shlex.quote(str(auth.parent))} && chmod 600 {shlex.quote(str(auth))}")
        for directory in ("/opt/stacks", "/opt/stacks/.ops", "/var/backups/stacks"):
            p = Path(directory)
            if p.is_dir() and self.sh(f"stat -c %U {directory}").stdout.strip() == user:
                self.ok(f"{directory} owned by {user}")
            elif self.change(f"create {directory} (owner {user}, 0750)"):
                self.sh(f"install -d -m 0750 -o {user} -g {user} {directory}")

    def sshd(self) -> None:
        if self.ensure_file(SSHD_DROPIN_PATH, SSHD_DROPIN):
            test = self.sh("sshd -t", check=False)
            if test.returncode != 0:
                os.remove(SSHD_DROPIN_PATH)
                raise RuntimeError(f"sshd -t rejected the drop-in (removed it): {test.stderr.strip()}")
            self.sh("systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true")

    def oracle_iptables(self) -> None:
        rules = self.sh("iptables -S INPUT", check=False).stdout
        if "-j REJECT" not in rules:
            self.ok("no host REJECT rule in INPUT (nothing to open)")
        for port in WEB_PORTS:
            rule = f"-p tcp -m state --state NEW -m tcp --dport {port} -j ACCEPT"
            if f"-A INPUT {rule}" in rules:
                self.ok(f"iptables INPUT accepts tcp/{port}")
            elif self.change(f"iptables: insert ACCEPT tcp/{port} before REJECT (live)"):
                listing = self.sh("iptables -L INPUT --line-numbers -n").stdout.splitlines()
                position = next((ln.split()[0] for ln in listing if " REJECT " in f" {ln} "), None)
                insert = f"-I INPUT {position}" if position else "-A INPUT"
                self.sh(f"iptables {insert} {rule}")
        persisted = Path("/etc/iptables/rules.v4")
        if not persisted.exists():
            self.ok("/etc/iptables/rules.v4 absent (no persisted host firewall)")
            return
        text = persisted.read_text()
        lines = text.splitlines()
        missing = [p for p in WEB_PORTS if f"-A INPUT -p tcp -m state --state NEW -m tcp --dport {p} -j ACCEPT" not in text]
        if not missing:
            self.ok("rules.v4 persists ACCEPT tcp/80,443")
            return
        if self.change(f"rules.v4: persist ACCEPT for tcp/{','.join(map(str, missing))} before the INPUT REJECT"):
            idx = next((i for i, ln in enumerate(lines) if ln.startswith("-A INPUT") and "-j REJECT" in ln), None)
            new_rules = [f"-A INPUT -p tcp -m state --state NEW -m tcp --dport {p} -j ACCEPT" for p in missing]
            if idx is None:
                idx = next((i for i, ln in enumerate(lines) if ln.strip() == "COMMIT"), len(lines))
            lines[idx:idx] = new_rules
            persisted.write_text("\n".join(lines) + "\n")

    def unattended_upgrades(self, reboot_time: str) -> None:
        self.ensure_file("/etc/apt/apt.conf.d/20auto-upgrades", AUTO_UPGRADES)
        self.ensure_file(
            "/etc/apt/apt.conf.d/52personal-infra-reboot",
            'Unattended-Upgrade::Automatic-Reboot "true";\n'
            f'Unattended-Upgrade::Automatic-Reboot-Time "{reboot_time}";\n',
        )

    def backup_units(self, user: str, stacks: list[str]) -> None:
        changed = self.ensure_file("/etc/systemd/system/stack-backup@.service", BACKUP_SERVICE.format(user=user))
        changed |= self.ensure_file("/etc/systemd/system/stack-backup@.timer", BACKUP_TIMER)
        if changed:
            self.sh("systemctl daemon-reload")
        for stack in stacks:
            unit = f"stack-backup@{stack}.timer"
            if self.sh(f"systemctl is-enabled {unit} && systemctl is-active {unit}", check=False).returncode == 0:
                self.ok(f"{unit} enabled")
            elif self.change(f"enable {unit}"):
                self.sh(f"systemctl enable --now {unit}")

    def host_key(self) -> None:
        r = self.sh("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub", check=False)
        if r.returncode == 0:
            print(f"[info] SSH host key (compare before trusting DEPLOY_KNOWN_HOSTS): {r.stdout.strip()}")


def remote_main(args: argparse.Namespace) -> int:
    if os.geteuid() != 0:
        print("[error] remote mode must run as root", file=sys.stderr)
        return 1
    pubkey = base64.b64decode(args.deploy_pubkey_b64).decode().strip() if args.deploy_pubkey_b64 else ""
    conv = Converger(check_only=args.mode == "check")
    steps = [
        ("os", conv.assert_ubuntu),
        ("apt", conv.apt_basics),
        ("docker", conv.docker),
        ("daemon", conv.docker_daemon_config),
        ("swap", lambda: conv.swap(args.swap_gb)),
        ("user", lambda: conv.deploy_user(args.deploy_user, pubkey)),
        ("sshd", conv.sshd),
        ("firewall", conv.oracle_iptables if args.provider == "oracle" else lambda: conv.ok("GCE: VPC firewall is the perimeter (no host rules)")),
        ("upgrades", lambda: conv.unattended_upgrades(args.reboot_time)),
        ("backups", lambda: conv.backup_units(args.deploy_user, args.backup_stack)),
    ]
    try:
        for name, step in steps:
            print(f"--- {name}")
            step()
    except RuntimeError as err:
        print(f"[error] {err}", file=sys.stderr)
        return 1
    conv.host_key()
    if conv.check_only:
        if conv.drift:
            print(f"[drift] {len(conv.drift)} item(s) differ from the desired state")
            return 2
        print("[ok] no drift")
    return 0


# ===========================================================================
# Local side
# ===========================================================================


def local_main(args: argparse.Namespace) -> int:
    pubkey = args.deploy_pubkey
    if args.deploy_pubkey_file:
        pubkey = Path(args.deploy_pubkey_file).expanduser().read_text().strip()
    if not pubkey or not pubkey.startswith(("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-", "sk-ssh-ed25519")):
        print("[error] --deploy-pubkey-file/--deploy-pubkey must be an OpenSSH PUBLIC key", file=sys.stderr)
        return 1

    mode = "check" if args.check else "apply"
    remote_args = [
        "--remote",
        "--mode", mode,
        "--provider", args.provider,
        "--deploy-user", args.deploy_user,
        "--deploy-pubkey-b64", base64.b64encode(pubkey.encode()).decode(),
        "--swap-gb", str(args.swap_gb),
        "--reboot-time", args.reboot_time,
    ]
    for stack in args.backup_stack:
        remote_args += ["--backup-stack", stack]

    ssh_cmd = ["ssh", "-o", "BatchMode=yes", "-o", f"StrictHostKeyChecking={args.host_key_checking}"]
    if args.identity_file:
        ssh_cmd += ["-i", str(Path(args.identity_file).expanduser()), "-o", "IdentitiesOnly=yes"]
    ssh_cmd += [args.host, "sudo python3 - " + shlex.join(remote_args)]

    if args.dry_run:
        print(f"[dry-run] Would run: {shlex.join(ssh_cmd)} < {Path(__file__).name}")
        print(f"[dry-run] Steps on {args.host} ({args.provider}): Ubuntu check, apt basics, Docker CE + compose plugin, "
              f"daemon.json + journald cap, {args.swap_gb}G swap, user '{args.deploy_user}' + deploy key, /opt/stacks, "
              f"sshd hardening, {'iptables 80/443 (live + rules.v4)' if args.provider == 'oracle' else 'no host firewall'}, "
              f"unattended-upgrades (reboot {args.reboot_time}), backup timers: {', '.join(args.backup_stack) or 'none'}")
        return 0

    print(f"[bootstrap] {'Checking' if args.check else 'Converging'} {args.host} ({args.provider}) ...")
    with open(__file__, "rb") as script:
        result = subprocess.run(ssh_cmd, stdin=script, check=False)
    if result.returncode == 0:
        print(f"[ok] {args.host} {'has no drift' if args.check else 'bootstrapped'}")
    elif result.returncode == 2 and args.check:
        print(f"[warn] {args.host} has drift; re-run without --check to converge")
    else:
        print(f"[error] bootstrap failed on {args.host} ({result.returncode})", file=sys.stderr)
    return result.returncode


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(description="Idempotently bootstrap an Ubuntu VM for docker compose stacks.")
    parser.add_argument("--host", default=os.environ.get("BOOTSTRAP_HOST", ""), help="Admin SSH target, e.g. ubuntu@203.0.113.10")
    parser.add_argument("--provider", choices=("oracle", "gce"), help="Cloud provider (oracle enables the host iptables step)")
    parser.add_argument("--deploy-user", default=DEFAULT_DEPLOY_USER, help=f"Unprivileged deploy user (default: {DEFAULT_DEPLOY_USER})")
    parser.add_argument("--deploy-pubkey-file", help="Public key file authorized for the deploy user (e.g. ~/.ssh/blog_deploy.pub)")
    parser.add_argument("--deploy-pubkey", default="", help="Public key string (alternative to --deploy-pubkey-file)")
    parser.add_argument("--swap-gb", type=int, default=DEFAULT_SWAP_GB, help=f"Swapfile size in GB (default: {DEFAULT_SWAP_GB})")
    parser.add_argument("--reboot-time", default=DEFAULT_REBOOT_TIME, help=f"Unattended-upgrades reboot time, UTC (default: {DEFAULT_REBOOT_TIME})")
    parser.add_argument("--backup-stack", action="append", default=[], help="Enable stack-backup@<name>.timer (repeatable)")
    parser.add_argument("--identity-file", help="Admin SSH private key")
    parser.add_argument("--host-key-checking", choices=("yes", "accept-new"), default="accept-new", help="StrictHostKeyChecking for the admin connection (default: accept-new)")
    parser.add_argument("--check", action="store_true", help="Report drift without changing anything (exit 2 on drift)")
    parser.add_argument("--dry-run", action="store_true", help="Print the SSH command and steps without connecting")
    # internal (remote side)
    parser.add_argument("--remote", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--mode", choices=("check", "apply"), default="apply", help=argparse.SUPPRESS)
    parser.add_argument("--deploy-pubkey-b64", default="", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.remote:
        sys.exit(remote_main(args))
    if not args.host or not args.provider:
        parser.error("--host and --provider are required")
    sys.exit(local_main(args))


if __name__ == "__main__":
    main()
