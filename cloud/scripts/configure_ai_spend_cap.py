#!/usr/bin/env python3
"""Idempotently configures GCP Cloud Billing Spend Cap budgets for AI services.

Uses the Google Cloud Billing Budget v1 REST API (`billingbudgets.googleapis.com`)
with the native `spendCap` guardrail (`inputState: CONFIGURED`) to automatically
pause eligible AI API usage when monthly gross estimated spend reaches 100% of
the configured cap.

Supported eligible AI services for GCP Spend Caps:
- `vertex-ai` (`services/C7E2-9256-1C43`): Vertex AI / Gemini Enterprise Agent
  Platform (`aiplatform.googleapis.com`), including 1P Gemini models and
  supported 3P Partner models (such as Anthropic Claude on Vertex AI).
- `gemini-api` (`services/AEFD-7695-64FA`): Gemini Developer API / Google AI
  Studio (`generativelanguage.googleapis.com`).
"""

import argparse
import json
import os
import subprocess
import sys
from typing import Any
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_CAP_USD = 1200
BUDGETS_API_BASE = "https://billingbudgets.googleapis.com/v1"

ELIGIBLE_AI_SERVICES: dict[str, dict[str, str]] = {
    "vertex-ai": {
        "service_id": "services/C7E2-9256-1C43",
        "api_name": "aiplatform.googleapis.com",
        "label": "Vertex AI",
    },
    "gemini-api": {
        "service_id": "services/AEFD-7695-64FA",
        "api_name": "generativelanguage.googleapis.com",
        "label": "Gemini API",
    },
}


def get_access_token() -> str:
    """Retrieves an OAuth2 bearer token from gcloud ADC (or CLI fallback)."""
    for cmd in (
        ["gcloud", "auth", "application-default", "print-access-token", "--quiet"],
        ["gcloud", "auth", "print-access-token", "--quiet"],
    ):
        try:
            res = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError as exc:
            raise RuntimeError("gcloud CLI not found in PATH") from exc
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    raise RuntimeError(
        "Failed to obtain gcloud access token (run `gcloud auth application-default login` or `gcloud auth login`)."
    )


def resolve_project_number(project_id: str) -> str:
    """Resolves a GCP project ID to its numeric project number."""
    try:
        res = subprocess.run(
            [
                "gcloud",
                "projects",
                "describe",
                project_id,
                "--format=value(projectNumber)",
                "--quiet",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("gcloud CLI not found in PATH") from exc
    if res.returncode != 0 or not res.stdout.strip():
        raise RuntimeError(
            f"Failed to resolve project number for '{project_id}': {res.stderr.strip()}"
        )
    return res.stdout.strip()


def resolve_billing_account(project_id: str) -> str:
    """Resolves the billingAccounts/<ID> linked to the target GCP project."""
    try:
        res = subprocess.run(
            [
                "gcloud",
                "billing",
                "projects",
                "describe",
                project_id,
                "--format=value(billingAccountName)",
                "--quiet",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("gcloud CLI not found in PATH") from exc
    if res.returncode != 0 or not res.stdout.strip():
        raise RuntimeError(
            f"Failed to resolve billing account for project '{project_id}': {res.stderr.strip()}"
        )
    billing_acct = res.stdout.strip()
    if not billing_acct.startswith("billingAccounts/"):
        billing_acct = f"billingAccounts/{billing_acct}"
    return billing_acct


def ensure_budgets_api_enabled(project_id: str, dry_run: bool = False) -> bool:
    """Ensures billingbudgets.googleapis.com is enabled on the quota project."""
    cmd = [
        "gcloud",
        "services",
        "enable",
        "billingbudgets.googleapis.com",
        f"--project={project_id}",
        "--quiet",
    ]
    if dry_run:
        print(f"[dry-run] Would ensure API enabled: {' '.join(cmd)}")
        return True

    res = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if res.returncode != 0:
        print(
            f"[error] Failed to enable billingbudgets.googleapis.com on '{project_id}': {res.stderr.strip()}",
            file=sys.stderr,
        )
        return False
    return True


def api_request(
    method: str,
    url: str,
    token: str,
    quota_project: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Executes an authenticated JSON request against the Cloud Billing Budget API."""
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Goog-User-Project": quota_project,
        "Content-Type": "application/json",
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"HTTP {exc.code} from {method} {url}: {err_body}"
        ) from exc


def list_budgets(
    billing_account: str,
    token: str,
    quota_project: str,
    project_scope: str = "",
) -> list[dict[str, Any]]:
    """Lists budgets under the specified Cloud Billing account (scoped to project if provided)."""
    budgets: list[dict[str, Any]] = []
    page_token = ""
    while True:
        params: dict[str, str] = {}
        if project_scope:
            params["scope"] = project_scope
        if page_token:
            params["pageToken"] = page_token
        query = f"?{urllib.parse.urlencode(params)}" if params else ""
        url = f"{BUDGETS_API_BASE}/{billing_account}/budgets{query}"
        resp = api_request("GET", url, token=token, quota_project=quota_project)
        budgets.extend(resp.get("budgets", []))
        page_token = resp.get("nextPageToken", "")
        if not page_token:
            break
    return budgets


def build_spend_cap_payload(
    project_id: str,
    project_ref: str,
    service_key: str,
    amount_usd: int,
    input_state: str = "CONFIGURED",
) -> dict[str, Any]:
    """Constructs a Cloud Billing Budget payload conforming to Spend Cap constraints."""
    svc_info = ELIGIBLE_AI_SERVICES[service_key]
    display_name = f"{project_id} - {svc_info['label']} Spend Cap"
    return {
        "displayName": display_name,
        "budgetFilter": {
            "projects": [project_ref],
            "services": [svc_info["service_id"]],
            "creditTypesTreatment": "EXCLUDE_ALL_CREDITS",
            "calendarPeriod": "MONTH",
        },
        "amount": {
            "specifiedAmount": {
                "currencyCode": "USD",
                "units": str(amount_usd),
                "nanos": 0,
            }
        },
        "thresholdRules": [
            {"thresholdPercent": 0.5, "spendBasis": "CURRENT_SPEND"},
            {"thresholdPercent": 0.8, "spendBasis": "CURRENT_SPEND"},
            {"thresholdPercent": 1.0, "spendBasis": "CURRENT_SPEND"},
        ],
        "notificationsRule": {
            "enableProjectLevelRecipients": True,
        },
        "ownershipScope": "ALL_USERS",
        "spendCap": {
            "inputState": input_state,
        },
    }


def find_existing_spend_cap_budget(
    budgets: list[dict[str, Any]],
    project_id: str,
    project_number: str,
    service_id: str,
) -> dict[str, Any] | None:
    """Finds an existing spend-cap budget matching the project and service."""
    valid_project_refs = {
        f"projects/{project_id}",
        f"projects/{project_number}",
    }
    for budget in budgets:
        if "spendCap" not in budget:
            continue
        b_filter = budget.get("budgetFilter", {})
        projects = set(b_filter.get("projects", []))
        services = set(b_filter.get("services", []))
        if (projects & valid_project_refs) and service_id in services:
            return budget
    return None


def sync_service_spend_cap(
    billing_account: str,
    project_id: str,
    project_number: str,
    service_key: str,
    amount_usd: int,
    input_state: str,
    existing_budgets: list[dict[str, Any]],
    token: str,
    dry_run: bool = False,
) -> bool:
    """Idempotently creates or updates a Spend Cap budget for a single AI service."""
    svc_info = ELIGIBLE_AI_SERVICES[service_key]
    project_ref = f"projects/{project_number}" if project_number else f"projects/{project_id}"
    payload = build_spend_cap_payload(
        project_id=project_id,
        project_ref=project_ref,
        service_key=service_key,
        amount_usd=amount_usd,
        input_state=input_state,
    )

    existing = find_existing_spend_cap_budget(
        budgets=existing_budgets,
        project_id=project_id,
        project_number=project_number,
        service_id=svc_info["service_id"],
    )

    if existing is None:
        create_url = f"{BUDGETS_API_BASE}/{billing_account}/budgets"
        if dry_run:
            print(
                f"[dry-run] Would POST new Spend Cap budget for {svc_info['label']} "
                f"({svc_info['api_name']} -> {svc_info['service_id']}) at ${amount_usd}/month:"
            )
            print(json.dumps(payload, indent=2))
            return True

        created = api_request(
            "POST",
            create_url,
            token=token,
            quota_project=project_id,
            payload=payload,
        )
        cap_obj = created.get("spendCap", {})
        cap_state = cap_obj.get("outputState") or cap_obj.get("state") or "CONFIGURED"
        print(
            f"[ok] Created Spend Cap budget '{created.get('displayName')}' "
            f"({created.get('name')}) -> ${amount_usd}/month [state={cap_state}]"
        )
        return True

    budget_name = existing["name"]
    current_units = (
        existing.get("amount", {}).get("specifiedAmount", {}).get("units", "")
    )
    cap_obj = existing.get("spendCap", {})
    current_state = cap_obj.get("outputState") or cap_obj.get("state") or ""
    desired_units = str(amount_usd)

    state_already_matches = (
        (input_state == "CONFIGURED" and current_state in ("CONFIGURED", "SPEND_CAP_CONFIGURED"))
        or (
            input_state == "AWAITING_NEXT_PERIOD"
            and current_state in ("AWAITING_NEXT_PERIOD", "SPEND_CAP_AWAITING_NEXT_PERIOD")
        )
    )

    if current_units == desired_units and state_already_matches:
        prefix = "[dry-run]" if dry_run else "[ok]"
        print(
            f"{prefix} Spend Cap budget for {svc_info['label']} ({budget_name}) "
            f"already converged at ${amount_usd}/month [state={current_state}]"
        )
        return True

    update_mask = "displayName,amount,spendCap"
    patch_url = (
        f"{BUDGETS_API_BASE}/{budget_name}?updateMask={urllib.parse.quote(update_mask)}"
    )
    patch_payload = dict(payload)
    patch_payload["name"] = budget_name
    if "etag" in existing:
        patch_payload["etag"] = existing["etag"]

    if dry_run:
        print(
            f"[dry-run] Would PATCH existing Spend Cap budget {budget_name} "
            f"(${current_units} -> ${desired_units}, state {current_state} -> {input_state}):"
        )
        print(json.dumps(patch_payload, indent=2))
        return True

    updated = api_request(
        "PATCH",
        patch_url,
        token=token,
        quota_project=project_id,
        payload=patch_payload,
    )
    updated_cap = updated.get("spendCap", {})
    new_state = updated_cap.get("outputState") or updated_cap.get("state") or input_state
    print(
        f"[ok] Updated Spend Cap budget '{updated.get('displayName')}' "
        f"({budget_name}) -> ${amount_usd}/month [state={new_state}]"
    )
    return True


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Configure or update GCP Cloud Billing Spend Cap budgets for AI services "
            "on a target project."
        )
    )
    parser.add_argument(
        "project_id",
        nargs="?",
        default=None,
        help="Target GCP project ID (can also be passed via --project / --project-id or GCP_PROJECT_ID).",
    )
    parser.add_argument(
        "--project",
        "--project-id",
        dest="project_flag",
        type=str,
        default=None,
        help="Target GCP project ID (overrides positional project_id and GCP_PROJECT_ID).",
    )
    parser.add_argument(
        "--project-number",
        type=str,
        default=os.environ.get("GCP_PROJECT_NUMBER", ""),
        help="Optional numeric GCP project number (auto-resolved via gcloud if omitted).",
    )
    parser.add_argument(
        "--billing-account",
        type=str,
        default=os.environ.get("GCP_BILLING_ACCOUNT_ID", ""),
        help="Optional Cloud Billing account ID (auto-resolved from project if omitted).",
    )
    parser.add_argument(
        "--amount",
        type=int,
        default=int(os.environ.get("AI_SPEND_CAP_USD", str(DEFAULT_CAP_USD))),
        help=f"Monthly spend cap amount in USD (default: {DEFAULT_CAP_USD}).",
    )
    parser.add_argument(
        "--services",
        nargs="+",
        choices=[*ELIGIBLE_AI_SERVICES.keys(), "all"],
        default=["vertex-ai"],
        help=(
            "AI services to cap: 'vertex-ai' (aiplatform.googleapis.com + 3P partner models), "
            "'gemini-api' (generativelanguage.googleapis.com), or 'all' (default: vertex-ai)."
        ),
    )
    parser.add_argument(
        "--lift",
        action="store_true",
        help="Manually lift an enforced spend cap for the remainder of the current month.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List existing budgets on the project's billing account and exit.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview API requests and payloads without mutating Cloud Billing budgets.",
    )
    args = parser.parse_args()

    project_id = (
        args.project_flag
        or args.project_id
        or os.environ.get("GCP_PROJECT_ID", "")
    ).strip()
    if not project_id:
        parser.error(
            "the following arguments are required: project_id (pass positionally, via --project/--project-id, or set GCP_PROJECT_ID)"
        )

    if args.amount <= 0:
        print("[error] --amount must be a positive integer in USD.", file=sys.stderr)
        sys.exit(1)

    selected_services = (
        list(ELIGIBLE_AI_SERVICES.keys())
        if "all" in args.services
        else list(dict.fromkeys(args.services))
    )
    input_state = "AWAITING_NEXT_PERIOD" if args.lift else "CONFIGURED"

    billing_account = args.billing_account.strip()
    if billing_account and not billing_account.startswith("billingAccounts/"):
        billing_account = f"billingAccounts/{billing_account}"
    project_number = args.project_number.strip()

    if args.dry_run and (not billing_account or not project_number):
        # Try resolving if gcloud is available/authenticated, else fall back to placeholders for CI
        try:
            if not billing_account:
                billing_account = resolve_billing_account(project_id)
            if not project_number:
                project_number = resolve_project_number(project_id)
        except RuntimeError:
            billing_account = billing_account or "billingAccounts/000000-000000-000000"
            project_number = project_number or project_id

    if not args.dry_run:
        if not ensure_budgets_api_enabled(project_id, dry_run=False):
            sys.exit(1)
        try:
            if not billing_account:
                billing_account = resolve_billing_account(project_id)
            if not project_number:
                project_number = resolve_project_number(project_id)
            project_scope = (
                f"projects/{project_number}"
                if project_number
                else f"projects/{project_id}"
            )
            token = get_access_token()
            existing_budgets = list_budgets(
                billing_account=billing_account,
                token=token,
                quota_project=project_id,
                project_scope=project_scope,
            )
        except RuntimeError as exc:
            print(f"[error] {exc}", file=sys.stderr)
            sys.exit(1)
    else:
        ensure_budgets_api_enabled(project_id, dry_run=True)
        token = ""
        existing_budgets = []
        try:
            token = get_access_token()
            project_scope = (
                f"projects/{project_number}"
                if project_number
                else f"projects/{project_id}"
            )
            existing_budgets = list_budgets(
                billing_account=billing_account,
                token=token,
                quota_project=project_id,
                project_scope=project_scope,
            )
        except RuntimeError:
            existing_budgets = []

    if args.list:
        print(json.dumps(existing_budgets, indent=2))
        sys.exit(0)

    for svc_key in selected_services:
        try:
            ok = sync_service_spend_cap(
                billing_account=billing_account,
                project_id=project_id,
                project_number=project_number,
                service_key=svc_key,
                amount_usd=args.amount,
                input_state=input_state,
                existing_budgets=existing_budgets,
                token=token,
                dry_run=args.dry_run,
            )
            if not ok:
                sys.exit(1)
        except RuntimeError as exc:
            print(f"[error] Failed to configure spend cap for '{svc_key}': {exc}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
