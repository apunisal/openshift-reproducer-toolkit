"""Validate local AWS / GCP credentials (used by prereqs, connect, and preflight)."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path


def validate_aws() -> tuple[bool, str]:
    """Return (ok, detail). Runs aws sts get-caller-identity when possible."""
    if not shutil.which("aws"):
        return False, "AWS CLI not installed. Install awscli and run: aws configure"

    creds = Path.home() / ".aws" / "credentials"
    if not creds.is_file():
        return (
            False,
            "Missing ~/.aws/credentials — run: aws configure "
            "(or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)",
        )

    key_id = _aws_configure_get("aws_access_key_id")
    secret = _aws_configure_get("aws_secret_access_key")
    if not key_id or not secret:
        return (
            False,
            "~/.aws/credentials exists but aws_access_key_id or aws_secret_access_key is empty. "
            "Run: aws configure",
        )

    try:
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity"],
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"AWS sts get-caller-identity failed: {exc}"

    if result.returncode != 0:
        err = (result.stderr or result.stdout or "unknown error").strip()
        return (
            False,
            f"AWS login rejected — sts get-caller-identity failed. "
            f"Check keys, session token expiry, and IAM permissions. Detail: {err}",
        )

    try:
        data = json.loads(result.stdout)
        arn = data.get("Arn") or data.get("UserId") or "authenticated"
        return True, f"Authenticated as {arn}"
    except json.JSONDecodeError:
        return True, (result.stdout or "Authenticated").strip().splitlines()[0]


def validate_gcp() -> tuple[bool, str]:
    """Return (ok, detail). Activates first ~/.gcp/*.json and verifies an active account."""
    gcp_dir = Path.home() / ".gcp"
    files = sorted(gcp_dir.glob("*.json")) if gcp_dir.is_dir() else []
    if not files:
        return (
            False,
            "No GCP service-account key in ~/.gcp/*.json — add a JSON key file there",
        )

    cred_file = files[0]
    if not shutil.which("gcloud"):
        if shutil.which("gsutil"):
            return (
                True,
                f"Found {cred_file.name}; gsutil present (gcloud recommended for full checks)",
            )
        return (
            False,
            f"Found {cred_file.name} but gcloud/gsutil not installed — install Google Cloud SDK",
        )

    try:
        activate = subprocess.run(
            ["gcloud", "auth", "activate-service-account", "--key-file", str(cred_file)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"gcloud auth activate-service-account failed: {exc}"

    if activate.returncode != 0:
        err = (activate.stderr or activate.stdout or "unknown error").strip()
        return (
            False,
            f"GCP service account activation failed for {cred_file.name}. "
            f"Check the JSON key is valid and not revoked. Detail: {err}",
        )

    try:
        active = subprocess.run(
            ["gcloud", "auth", "list", "--filter=status:ACTIVE", "--format=value(account)"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"gcloud auth list failed after activation: {exc}"

    account = (active.stdout or "").strip().splitlines()[0] if active.stdout else ""
    if active.returncode != 0 or not account:
        err = (active.stderr or active.stdout or "no active account").strip()
        return False, f"GCP has no active account after activation. Detail: {err}"

    return True, f"Authenticated as {account} (key: {cred_file.name})"


def validate_for_platform(platform: str | None) -> tuple[bool, str]:
    """Validate cloud credentials for the connected cluster platform."""
    if platform == "AWS":
        return validate_aws()
    if platform == "GCP":
        return validate_gcp()
    if not platform:
        return False, "Could not detect cluster platform (infrastructure/cluster)."
    return False, f"Unsupported platform for Loki/ACM storage: {platform}"


def _aws_configure_get(key: str) -> str:
    try:
        result = subprocess.run(
            ["aws", "configure", "get", key],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if result.returncode == 0:
            return (result.stdout or "").strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ""
