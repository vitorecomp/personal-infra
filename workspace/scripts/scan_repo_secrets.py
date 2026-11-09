#!/usr/bin/env python3
"""Scans Git repositories for accidentally committed or staged keys, tokens, and secrets.

Behavior:
1. Defaults to scanning the `personal-infra` repository (or any repository / workspace
   folder passed via positional `target` or `--target`).
2. Checks three layers of protection:
   - Forbidden secret/credential filenames tracked or staged in Git (e.g., `.env`,
     `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `*sa-key*.json`, `*.tfvars`, `*.tfstate`),
     plus any unignored secret files in the working tree.
   - Known cryptographic key blocks and cloud/API token formats (PEM/OpenSSH/PGP private
     keys, GCP Service Account JSON keys, Google API/OAuth keys, GitHub PATs, AWS access
     keys, Ghost Admin API keys, Slack/AI tokens, JWTs, URLs with embedded credentials).
   - Hardcoded high-entropy secret/password/token literals in source or config files.
3. Supports:
   - `--staged`: Fast index-only scan (`git diff --cached`) designed for `.git/hooks/pre-commit`.
   - `--history`: Full Git commit history blob scan (`git rev-list --objects --all`).
   - `--install-hook`: Idempotently installs a managed `.git/hooks/pre-commit` hook.
   - `--self-test`: Verifies detection and allowlist rules against synthetic in-memory samples.
   - `--dry-run`: Previews repositories/hooks that would be scanned or installed without failing or mutating disk.
4. Redacts matched secret values in all console output so CI logs never echo sensitive material.
"""

import argparse
from dataclasses import dataclass, field
import fnmatch
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

SCRIPT_PATH = Path(__file__).resolve()
PROJECT_ROOT = SCRIPT_PATH.parent.parent.parent
DEFAULT_WORKSPACE = Path.home() / "workspace"
MANAGED_HOOK_MARKER = "# MANAGED BY personal-infra/workspace/scripts/scan_repo_secrets.py"
INLINE_ALLOW_MARKERS = ("# nosecret", "# pragma: allowlist secret", "<!-- nosecret -->")

SKIP_DIRS = {
    ".git",
    ".terraform",
    "node_modules",
    "__pycache__",
    ".venv",
    "venv",
    "dist",
    "build",
    "target",
}

ALLOWED_EXAMPLE_SUFFIXES = (
    ".example",
    ".sample",
    ".template",
    ".dist",
)

FORBIDDEN_EXACT_FILENAMES = {
    ".env",
    ".secrets",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".htpasswd",
    "application_default_credentials.json",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "id_ecdsa_sk",
    "id_ed25519_sk",
    "kubeconfig",
    "terraform.tfstate",
    "tfplan",
}

FORBIDDEN_FILE_GLOBS = (
    ".env.*",
    "*.secret",
    "secrets.json",
    "secrets.yaml",
    "secrets.yml",
    "*sa-key*.json",
    "*credentials*.json",
    "*-key.json",
    "*service-account*.json",
    "*service_account*.json",
    "client_secret*.json",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.p8",
    "*.pkcs12",
    "*.ppk",
    "*.jks",
    "*.keystore",
    "*.kdbx",
    "*.ovpn",
    "*.kubeconfig",
    "*_rsa",
    "*_ed25519",
    "*.tfvars",
    "*.tfvars.json",
    "*.tfstate",
    "*.tfstate.*",
    "*.tfplan",
)

LINE_SECRET_RULES: list[tuple[str, re.Pattern[str]]] = [
    (
        "private-key-block",
        re.compile(
            r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY(?:\s+BLOCK)?-----"
            r"|^PuTTY-User-Key-File-\d+:"
        ),
    ),
    (
        "gcp-sa-private-key",
        re.compile(r'"private_key"\s*:\s*"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'),
    ),
    (
        "google-api-key",
        re.compile(r"\bAIza[0-9A-Za-z\-_]{35}\b"),
    ),
    (
        "google-oauth-client-secret",
        re.compile(r"\bGOCSPX-[0-9A-Za-z\-_]{20,}\b"),
    ),
    (
        "google-oauth-access-token",
        re.compile(r"\bya29\.[0-9A-Za-z\-_]{25,}\b"),
    ),
    (
        "github-token",
        re.compile(
            r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"
            r"|\bgithub_pat_[A-Za-z0-9_]{30,}\b"
        ),
    ),
    (
        "aws-access-key-id",
        re.compile(
            r"\b(?:A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}\b"
        ),
    ),
    (
        "ai-api-key",
        re.compile(r"\bsk-(?:proj-|ant-|live-|test-)?[A-Za-z0-9\-_]{24,}\b"),
    ),
    (
        "slack-token",
        re.compile(r"\bxox[baprs]-[0-9A-Za-z\-]{10,}\b"),
    ),
    (
        "ghost-admin-api-key",
        re.compile(r"\b[0-9a-f]{24}:[0-9a-f]{64}\b", re.IGNORECASE),
    ),
    (
        "jwt-token",
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"
        ),
    ),
]

GCP_SA_TYPE_RE = re.compile(r'"type"\s*:\s*"service_account"')
GCP_SA_KEY_ID_RE = re.compile(r'"private_key_id"\s*:\s*"([0-9a-fA-F]{16,})"')

URL_CREDENTIAL_RE = re.compile(
    r"\b(?:https?|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp|ssh|sftp)://"
    r"([^/\s:@<$\"'{]+):([^/\s@<$\"'{]{4,})@([^/\s\"']+)"
)

SECRET_ASSIGNMENT_RE = re.compile(
    r"""(?ix)
    \b(
        [a-z0-9_]*?(?:
            password | passwd | pwd | secret | secret_key |
            api_key | apikey | access_key | private_key | client_secret |
            auth_token | access_token | refresh_token |
            github_token | metrics_token | personal_infra_token | sa_key
        )
    )\b
    \s*(?:=|:)\s*
    (?:
        '([^'\r\n]{8,})' |
        "([^"\r\n]{8,})"
    )
    """
)

AWS_EXAMPLE_KEYS = {"AKIAIOSFODNN7EXAMPLE", "ASIAIOSFODNN7EXAMPLE"}
SAFE_URL_PASSWORDS = {
    "pass",
    "password",
    "pwd",
    "secret",
    "token",
    "postgres",
    "mysql",
    "taiga",
    "ghost",
    "changeme",
    "example",
}
SAFE_VALUE_PREFIXES = (
    "build-time-",
    "local-dev-",
    "taiga-local-dev-",
    "ci-",
    "test-",
    "dummy-",
    "fake-",
    "mock-",
    "example-",
    "placeholder",
    "changeme",
    "your-",
    "your_",
)


@dataclass
class SecretFinding:
    source: str
    location: str
    rule: str
    detail: str


@dataclass
class RepoScanResult:
    path: Path
    files_scanned: int = 0
    blobs_scanned: int = 0
    findings: list[SecretFinding] = field(default_factory=list)
    error: str | None = None


def shannon_entropy(value: str) -> float:
    if not value:
        return 0.0
    counts: dict[str, int] = {}
    for ch in value:
        counts[ch] = counts.get(ch, 0) + 1
    length = len(value)
    return -sum((count / length) * math.log2(count / length) for count in counts.values())


def redact_secret(value: str) -> str:
    cleaned = value.strip()
    if len(cleaned) <= 8:
        return "***REDACTED***"
    return f"{cleaned[:4]}...{cleaned[-2:]} (len={len(cleaned)})"


def run_git(repo_path: Path, args: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", "-C", str(repo_path), *args],
        check=False,
        capture_output=True,
    )


def is_forbidden_secret_path(rel_path: str) -> str | None:
    norm = rel_path.replace("\\", "/")
    while norm.startswith("./"):
        norm = norm[2:]
    name = Path(norm).name
    lower_name = name.lower()

    if any(lower_name.endswith(suffix) for suffix in ALLOWED_EXAMPLE_SUFFIXES):
        return None

    if name in FORBIDDEN_EXACT_FILENAMES or lower_name in FORBIDDEN_EXACT_FILENAMES:
        return f"forbidden credential/state filename '{name}'"

    for pattern in FORBIDDEN_FILE_GLOBS:
        if fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(lower_name, pattern.lower()):
            return f"matches forbidden secret file pattern '{pattern}'"

    return None


def _is_placeholder_secret_value(var_name: str, value: str) -> bool:
    stripped = value.strip()
    lower = stripped.lower()

    if not stripped or len(stripped) < 8:
        return True

    # Ignore variable interpolations, templates, CLI flags, and placeholders.
    if (
        "${" in stripped
        or "{{" in stripped
        or stripped.startswith(("$", "<", "--", "env:", "file:"))
        or (stripped.startswith("<") and stripped.endswith(">"))
    ):
        return True

    if any(lower.startswith(prefix) for prefix in SAFE_VALUE_PREFIXES):
        return True

    if any(
        token in lower
        for token in (
            "placeholder",
            "changeme",
            "change-in-prod",
            "collectstatic",
            "example",
            "redacted",
            "ghp_xxx",
            "xxxx",
        )
    ):
        return True

    # Ignore non-secret path/URL/header constants assigned to similarly named config keys.
    if stripped.startswith(("/", "./", "../", "~/", "http://", "https://", "projects/", "roles/")):
        return True
    if lower_var := var_name.lower():
        if lower_var.endswith(("_path", "_file", "_dir", "_url", "_endpoint", "_header", "_name", "_env")):
            return True

    # Require realistic entropy or mixed secret character classes to avoid flagging plain prose.
    if " " in stripped and len(stripped) < 20:
        return True

    entropy = shannon_entropy(stripped)
    has_upper = any(c.isupper() for c in stripped)
    has_lower = any(c.islower() for c in stripped)
    has_digit = any(c.isdigit() for c in stripped)
    has_symbol = any(not c.isalnum() for c in stripped)
    char_classes = sum((has_upper, has_lower, has_digit, has_symbol))

    if entropy < 3.3 and char_classes < 3:
        return True

    return False


def scan_blob_bytes(
    raw: bytes,
    location: str,
    source: str,
) -> list[SecretFinding]:
    findings: list[SecretFinding] = []

    # Check binary files only for embedded PEM/service-account markers.
    if b"\x00" in raw[:8192]:
        if b"PRIVATE KEY-----" in raw:
            findings.append(
                SecretFinding(
                    source=source,
                    location=location,
                    rule="private-key-block",
                    detail="binary file contains PEM/OpenSSH PRIVATE KEY header",
                )
            )
        return findings

    text = raw.decode("utf-8", errors="replace")

    if GCP_SA_TYPE_RE.search(text):
        key_id_match = GCP_SA_KEY_ID_RE.search(text)
        if key_id_match:
            findings.append(
                SecretFinding(
                    source=source,
                    location=location,
                    rule="gcp-service-account-json",
                    detail=(
                        "GCP service_account JSON with private_key_id "
                        f"{redact_secret(key_id_match.group(1))}"
                    ),
                )
            )

    for lineno, line in enumerate(text.splitlines(), 1):
        if any(marker in line for marker in INLINE_ALLOW_MARKERS):
            continue

        line_loc = f"{location}:{lineno}"

        for rule_name, pattern in LINE_SECRET_RULES:
            for match in pattern.finditer(line):
                matched = match.group(0)
                if rule_name == "aws-access-key-id" and matched in AWS_EXAMPLE_KEYS:
                    continue
                findings.append(
                    SecretFinding(
                        source=source,
                        location=line_loc,
                        rule=rule_name,
                        detail=f"matched {redact_secret(matched)}",
                    )
                )

        for url_match in URL_CREDENTIAL_RE.finditer(line):
            user_part, pass_part, _ = url_match.groups()
            if (
                pass_part.lower() in SAFE_URL_PASSWORDS
                or user_part.lower() in {"user", "username", "<user>"}
                or pass_part.startswith(("$", "<", "{"))
            ):
                continue
            findings.append(
                SecretFinding(
                    source=source,
                    location=line_loc,
                    rule="url-embedded-credentials",
                    detail=f"credentials for '{user_part}' ({redact_secret(pass_part)})",
                )
            )

        for assign_match in SECRET_ASSIGNMENT_RE.finditer(line):
            var_name = assign_match.group(1)
            val = assign_match.group(2) or assign_match.group(3) or ""
            if _is_placeholder_secret_value(var_name, val):
                continue
            findings.append(
                SecretFinding(
                    source=source,
                    location=line_loc,
                    rule="hardcoded-secret-assignment",
                    detail=f"{var_name}={redact_secret(val)}",
                )
            )

    return findings


def resolve_target_repos(target: str | None) -> list[Path]:
    if not target:
        return [PROJECT_ROOT]

    candidate = Path(target).expanduser()
    if not candidate.exists():
        ws_candidate = DEFAULT_WORKSPACE / target
        if ws_candidate.exists():
            candidate = ws_candidate
    candidate = candidate.resolve()

    if not candidate.exists():
        return []

    if (candidate / ".git").exists():
        return [candidate]

    # Discover nested Git repositories when pointed at a workspace category directory.
    repos: list[Path] = []
    seen: set[Path] = set()

    def _walk(current: Path) -> None:
        if (current / ".git").exists():
            real = current.resolve()
            if real not in seen:
                seen.add(real)
                repos.append(current)
            return
        try:
            children = sorted(current.iterdir())
        except OSError:
            return
        for child in children:
            if child.is_symlink() or not child.is_dir():
                continue
            if child.name.startswith(".") or child.name in SKIP_DIRS:
                continue
            _walk(child)

    _walk(candidate)
    return repos


def scan_repository(
    repo_path: Path,
    staged_only: bool = False,
    include_history: bool = False,
    check_untracked: bool = True,
) -> RepoScanResult:
    result = RepoScanResult(path=repo_path)

    # 1. Scan staged files in the index (always scanned in --staged mode, and included in default mode).
    staged_res = run_git(
        repo_path, ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"]
    )
    if staged_res.returncode != 0:
        result.error = f"git diff --cached failed: {staged_res.stderr.decode('utf-8', 'replace').strip()}"
        return result

    staged_paths = [
        p.decode("utf-8", errors="replace")
        for p in staged_res.stdout.split(b"\x00")
        if p
    ]

    for rel_path in staged_paths:
        reason = is_forbidden_secret_path(rel_path)
        if reason:
            result.findings.append(
                SecretFinding(
                    source="staged",
                    location=rel_path,
                    rule="forbidden-secret-file",
                    detail=reason,
                )
            )
        blob_res = run_git(repo_path, ["show", f":{rel_path}"])
        if blob_res.returncode == 0:
            result.files_scanned += 1
            result.findings.extend(
                scan_blob_bytes(blob_res.stdout, location=rel_path, source="staged")
            )

    if staged_only:
        return result

    # 2. Scan all tracked files in the working tree (skipping files already scanned from index if identical).
    ls_res = run_git(repo_path, ["ls-files", "-z"])
    if ls_res.returncode != 0:
        result.error = f"git ls-files failed: {ls_res.stderr.decode('utf-8', 'replace').strip()}"
        return result

    tracked_paths = [
        p.decode("utf-8", errors="replace") for p in ls_res.stdout.split(b"\x00") if p
    ]
    staged_set = set(staged_paths)

    for rel_path in tracked_paths:
        if rel_path not in staged_set:
            reason = is_forbidden_secret_path(rel_path)
            if reason:
                result.findings.append(
                    SecretFinding(
                        source="tracked",
                        location=rel_path,
                        rule="forbidden-secret-file",
                        detail=reason,
                    )
                )
        full_path = repo_path / rel_path
        if not full_path.is_file() or full_path.is_symlink():
            continue
        try:
            raw = full_path.read_bytes()
        except OSError:
            continue
        result.files_scanned += 1
        result.findings.extend(
            scan_blob_bytes(raw, location=rel_path, source="working-tree")
        )

    # 3. Check for unignored secret files sitting in the working tree (ready to be `git add .`'d).
    if check_untracked:
        untracked_res = run_git(
            repo_path, ["ls-files", "--others", "--exclude-standard", "-z"]
        )
        if untracked_res.returncode == 0:
            for raw_rel in untracked_res.stdout.split(b"\x00"):
                if not raw_rel:
                    continue
                rel_path = raw_rel.decode("utf-8", errors="replace")
                reason = is_forbidden_secret_path(rel_path)
                if reason:
                    result.findings.append(
                        SecretFinding(
                            source="untracked-unignored",
                            location=rel_path,
                            rule="unignored-secret-file",
                            detail=f"{reason} (not covered by .gitignore)",
                        )
                    )
                untracked_full = repo_path / rel_path
                if untracked_full.is_file() and not untracked_full.is_symlink():
                    try:
                        raw_untracked = untracked_full.read_bytes()
                    except OSError:
                        continue
                    result.files_scanned += 1
                    result.findings.extend(
                        scan_blob_bytes(
                            raw_untracked,
                            location=rel_path,
                            source="untracked-unignored",
                        )
                    )

    # 4. Optionally scan all reachable blobs in Git commit history.
    if include_history:
        rev_res = run_git(repo_path, ["rev-list", "--objects", "--all"])
        if rev_res.returncode != 0:
            result.error = (
                f"git rev-list failed: {rev_res.stderr.decode('utf-8', 'replace').strip()}"
            )
            return result

        blob_paths: dict[str, str] = {}
        for raw_line in rev_res.stdout.decode("utf-8", errors="replace").splitlines():
            parts = raw_line.split(" ", 1)
            if len(parts) == 2 and parts[1]:
                blob_paths.setdefault(parts[0], parts[1])

        for sha, hist_path in blob_paths.items():
            type_res = run_git(repo_path, ["cat-file", "-t", sha])
            if type_res.returncode != 0 or type_res.stdout.strip() != b"blob":
                continue

            reason = is_forbidden_secret_path(hist_path)
            if reason:
                result.findings.append(
                    SecretFinding(
                        source=f"history:{sha[:8]}",
                        location=hist_path,
                        rule="forbidden-secret-file",
                        detail=reason,
                    )
                )

            cat_res = run_git(repo_path, ["cat-file", "blob", sha])
            if cat_res.returncode != 0:
                continue
            result.blobs_scanned += 1
            result.findings.extend(
                scan_blob_bytes(
                    cat_res.stdout,
                    location=hist_path,
                    source=f"history:{sha[:8]}",
                )
            )

    # Deduplicate identical rule+location findings between staged and working-tree.
    deduped: list[SecretFinding] = []
    seen_keys: set[tuple[str, str, str]] = set()
    for item in result.findings:
        key = (
            item.source if item.source.startswith("history:") else "current",
            item.location,
            item.rule,
        )
        if key not in seen_keys:
            seen_keys.add(key)
            deduped.append(item)
    result.findings = deduped
    return result


def build_pre_commit_hook_content() -> str:
    return (
        "#!/usr/bin/env sh\n"
        f"{MANAGED_HOOK_MARKER}\n"
        "# Blocks commits containing private keys, cloud credentials, API tokens, or secret files.\n"
        "set -eu\n\n"
        'REPO_ROOT="$(git rev-parse --show-toplevel)"\n'
        'if [ -f "${REPO_ROOT}/workspace/scripts/scan_repo_secrets.py" ]; then\n'
        '  exec python3 "${REPO_ROOT}/workspace/scripts/scan_repo_secrets.py" --staged "${REPO_ROOT}"\n'
        "fi\n"
        f'exec python3 "{SCRIPT_PATH}" --staged "${{REPO_ROOT}}"\n'
    )


def install_pre_commit_hook(
    repo_path: Path,
    force: bool = False,
    dry_run: bool = False,
) -> int:
    hook_path_res = run_git(repo_path, ["rev-parse", "--git-path", "hooks/pre-commit"])
    if hook_path_res.returncode != 0:
        print(
            f"[error] {repo_path}: unable to resolve git hooks path.",
            file=sys.stderr,
        )
        return 1

    raw_hook_path = Path(hook_path_res.stdout.decode("utf-8", errors="replace").strip())
    hook_path = (
        raw_hook_path
        if raw_hook_path.is_absolute()
        else (repo_path / raw_hook_path).resolve()
    )
    desired = build_pre_commit_hook_content()

    if hook_path.exists():
        existing = hook_path.read_text(encoding="utf-8", errors="replace")
        is_executable = bool(hook_path.stat().st_mode & stat.S_IXUSR)
        if existing == desired and is_executable:
            prefix = "[dry-run]" if dry_run else "[ok]"
            print(f"{prefix} Pre-commit secret hook already up to date at {hook_path}")
            return 0
        if MANAGED_HOOK_MARKER not in existing and not force:
            print(
                f"[error] Custom pre-commit hook already exists at {hook_path}; "
                "re-run with --force-hook to replace it.",
                file=sys.stderr,
            )
            return 1

    if dry_run:
        action = "update" if hook_path.exists() else "create"
        print(f"[dry-run] Would {action} executable pre-commit hook at {hook_path}")
        return 0

    hook_path.parent.mkdir(parents=True, exist_ok=True)
    hook_path.write_text(desired, encoding="utf-8")
    current_mode = hook_path.stat().st_mode
    hook_path.chmod(current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"[ok] Installed pre-commit secret-scanning hook at {hook_path}")
    return 0


def run_self_test() -> int:
    """Validates detection rules and placeholder exclusions using dynamically assembled samples."""
    must_detect: list[tuple[str, bytes, str]] = [
        (
            "pem-key",
            "".join(["-----BEGIN ", "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE=\n"]).encode(),
            "private-key-block",
        ),
        (
            "gcp-sa-json",
            "".join(
                [
                    '{\n  "type": ',
                    '"service_account",\n  "private_key',
                    '_id": "',
                    "a1b2c3d4e5f60718293a4b5c6d7e8f90",
                    '"\n}\n',
                ]
            ).encode(),
            "gcp-service-account-json",
        ),
        (
            "google-api-key",
            "".join(["SAMPLE_", "KEY", " = ", "'AIza", "SyDa1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6'\n"]).encode(),
            "google-api-key",
        ),
        (
            "github-pat",
            "".join(["export ", "TOK", "=", "ghp_", "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8\n"]).encode(),
            "github-token",
        ),
        (
            "aws-key",
            "".join(["aws_id", " = ", "'AKIA", "Z7X8C9V0B1N2M3Q4'\n"]).encode(),
            "aws-access-key-id",
        ),
        (
            "ghost-key",
            "".join(["GHOST_", "KEY=", "ab12cd34" * 3, ":", "9f8e7d6c" * 8, "\n"]).encode(),
            "ghost-admin-api-key",
        ),
        (
            "hardcoded-password",
            "".join(["MOCK_API_", "PASS", "WORD", ' = "', "Synth9#", "Vector2$", 'Check8!"\n']).encode(),
            "hardcoded-secret-assignment",
        ),
    ]

    must_ignore: list[tuple[str, bytes]] = [
        ("env-var-placeholder", b"ADMIN_PASSWORD=<your_password_here>\n"),
        ("docker-build-dummy", b'POSTGRES_PASSWORD="build-time-password"\n'),
        ("compose-default", b"POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-taiga-local-dev-password}\n"),
        ("ci-dummy", b"BLOG_ADMIN_PASSWORD=ci-pass\n"),
        ("doc-pat-placeholder", b"GITHUB_TOKEN=ghp_xxx python3 script.py\n"),
        ("path-constant", b'TOKEN_CACHE_PATH = "/home/user/.cache/taiga_cli/token.json"\n'),
        ("aws-doc-example", ("key = '" + "AKIA" + "IOSFODNN7EXAMPLE'\n").encode()),
    ]

    self_findings = scan_blob_bytes(
        SCRIPT_PATH.read_bytes(),
        location="workspace/scripts/scan_repo_secrets.py",
        source="selftest",
    )
    if self_findings:
        print(
            f"[error] Self-test failed: scanner flagged its own source file: {self_findings}",
            file=sys.stderr,
        )
        return 1

    for label, payload, expected_rule in must_detect:
        findings = scan_blob_bytes(payload, location=f"selftest/{label}", source="selftest")
        matched_rules = {f.rule for f in findings}
        if expected_rule not in matched_rules:
            print(
                f"[error] Self-test failed: '{label}' did not trigger '{expected_rule}' "
                f"(got {sorted(matched_rules)})",
                file=sys.stderr,
            )
            return 1

    for label, payload in must_ignore:
        findings = scan_blob_bytes(payload, location=f"selftest/{label}", source="selftest")
        if findings:
            print(
                f"[error] Self-test false positive on '{label}': {findings}",
                file=sys.stderr,
            )
            return 1

    if not is_forbidden_secret_path(".env") or not is_forbidden_secret_path("keys/id_ed25519"):
        print("[error] Self-test failed on forbidden filename detection.", file=sys.stderr)
        return 1
    if is_forbidden_secret_path(".env.example") or is_forbidden_secret_path("cloud/infra/envs/prod/terraform.tfvars.example"):
        print("[error] Self-test failed on allowed .example template path.", file=sys.stderr)
        return 1

    print(
        f"[ok] Secret scanner self-test passed ({len(must_detect)} positive cases, "
        f"{len(must_ignore)} safe placeholder cases, filename filters)."
    )
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Scan Git repositories for committed or staged keys, tokens, and secrets."
    )
    parser.add_argument(
        "target",
        nargs="?",
        default=None,
        help="Optional target repository or workspace folder (default: personal-infra root).",
    )
    parser.add_argument(
        "-t",
        "--target",
        dest="target_flag",
        type=str,
        default=None,
        help="Target repository path or category name under ~/workspace.",
    )
    parser.add_argument(
        "--staged",
        action="store_true",
        help="Scan only staged files in the Git index (used by the pre-commit hook).",
    )
    parser.add_argument(
        "--history",
        action="store_true",
        help="Also scan all reachable blobs across the entire Git commit history.",
    )
    parser.add_argument(
        "--no-untracked",
        action="store_true",
        help="Skip checking for unignored secret filenames in the working tree.",
    )
    parser.add_argument(
        "--install-hook",
        action="store_true",
        help="Idempotently install a pre-commit hook in each target repository.",
    )
    parser.add_argument(
        "--force-hook",
        action="store_true",
        help="Overwrite an existing non-managed pre-commit hook when used with --install-hook.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run built-in secret detection self-tests and exit.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print detailed per-repository scan counts.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview repositories and hook installations without modifying files or failing.",
    )
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test())

    selected_target = args.target_flag or args.target
    repos = resolve_target_repos(selected_target)
    if not repos:
        if args.dry_run:
            print(f"[dry-run] No Git repositories found for target '{selected_target}'.")
            sys.exit(0)
        print(
            f"[error] No Git repositories found for target '{selected_target or PROJECT_ROOT}'.",
            file=sys.stderr,
        )
        sys.exit(1)

    exit_code = 0

    if args.install_hook:
        for repo in repos:
            rc = install_pre_commit_hook(
                repo_path=repo,
                force=args.force_hook,
                dry_run=args.dry_run,
            )
            if rc != 0:
                exit_code = 1
        if not args.history and not args.staged and selected_target is None and exit_code != 0:
            sys.exit(exit_code)

    if args.dry_run:
        scope = "staged index" if args.staged else ("tracked files + full history" if args.history else "tracked + staged files")
        print(
            f"[dry-run] Would scan {len(repos)} Git repository(ies) ({scope}): "
            + ", ".join(str(r) for r in repos)
        )
        sys.exit(exit_code)

    total_findings = 0
    total_errors = 0

    for repo in repos:
        res = scan_repository(
            repo_path=repo,
            staged_only=args.staged,
            include_history=args.history,
            check_untracked=not args.no_untracked,
        )
        if res.error:
            total_errors += 1
            print(f"[error] {repo.name}: {res.error}", file=sys.stderr)
            continue

        if res.findings:
            total_findings += len(res.findings)
            print(
                f"[secret-detected] {repo.name}: {len(res.findings)} potential secret/key finding(s):",
                file=sys.stderr,
            )
            for finding in res.findings:
                print(
                    f"  - [{finding.source}] {finding.location} ({finding.rule}): {finding.detail}",
                    file=sys.stderr,
                )
        elif args.verbose or not args.staged:
            hist_note = f", {res.blobs_scanned} history blobs" if args.history else ""
            print(
                f"[ok] {repo.name}: no keys or secrets found "
                f"({res.files_scanned} files{hist_note} scanned)."
            )

    if total_findings > 0:
        if args.staged:
            print(
                "\n[blocked] Commit aborted by scan_repo_secrets.py. "
                "Move credentials to environment variables / GitHub Secrets or gitignore the file.",
                file=sys.stderr,
            )
        sys.exit(1)

    if total_errors > 0:
        sys.exit(1)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
