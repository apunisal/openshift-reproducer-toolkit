"""Pre-deploy validation before running install scripts."""

from __future__ import annotations

import shutil
import subprocess

from app.services.cloud_creds import validate_for_platform


def run_preflight(selected: dict[str, bool], platform: str | None) -> dict:
    """Return {ok, errors[], warnings[]} before starting deploy."""
    errors: list[str] = []
    warnings: list[str] = []

    admin = subprocess.run(
        ["oc", "auth", "can-i", "*", "*", "--all-namespaces"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if admin.returncode != 0 or admin.stdout.strip() != "yes":
        errors.append(
            "cluster-admin privileges required — re-connect with a cluster-admin account."
        )

    if selected.get("loki_alerting") and not selected.get("loki"):
        errors.append("Per-user Loki log alerting requires Loki logging to be selected.")

    needs_cloud = selected.get("loki") or selected.get("acm") or selected.get("gpu")
    if needs_cloud:
        if not platform:
            errors.append("Could not detect cluster platform — reconnect to the cluster.")
        else:
            ok, detail = validate_for_platform(platform)
            if not ok:
                errors.append(f"Cloud credentials ({platform}): {detail}")

    if selected.get("gpu"):
        if platform != "AWS":
            errors.append("GPU nodes option requires an AWS cluster.")
        if not shutil.which("jq"):
            errors.append("jq is required for the GPU script — install jq and re-check prerequisites.")

    needs_users = selected.get("users") or selected.get("loki_alerting")
    if needs_users:
        if not shutil.which("htpasswd"):
            errors.append(
                "htpasswd is required for user scripts — install httpd-tools (or apache2-utils) "
                "and re-check prerequisites."
            )

    if selected.get("loki") or selected.get("acm"):
        if not shutil.which("openssl"):
            errors.append("openssl is required for Loki/ACM bucket naming — install openssl.")

    if selected.get("loki") or selected.get("acm"):
        if platform == "GCP" and not shutil.which("gcloud") and not shutil.which("gsutil"):
            errors.append("gcloud or gsutil required for GCP storage in Loki/ACM scripts.")

    return {"ok": len(errors) == 0, "errors": errors, "warnings": warnings}
