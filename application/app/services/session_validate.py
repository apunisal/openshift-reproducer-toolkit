"""Validate an active OpenShift session before the wizard continues."""

from __future__ import annotations

import shutil
import subprocess

from app.services.cloud_creds import validate_for_platform
from app.services.cluster import ClusterInfo


def validate_session(info: ClusterInfo) -> dict:
    """Return {ok, errors[], warnings[]} after oc login."""
    errors: list[str] = []
    warnings: list[str] = []

    if not info.connected:
        errors.append(info.error or "Not logged in to a cluster.")
        return {"ok": False, "errors": errors, "warnings": warnings}

    admin = subprocess.run(
        ["oc", "auth", "can-i", "*", "*", "--all-namespaces"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if admin.returncode != 0 or admin.stdout.strip() != "yes":
        errors.append(
            "cluster-admin required — the logged-in user cannot manage all resources. "
            "Log in as kubeadmin or another cluster-admin account."
        )

    if not info.openshift_version:
        warnings.append("Could not read OpenShift version from clusterversion/version.")

    cloud_ok, cloud_detail = validate_for_platform(info.platform)
    if not cloud_ok:
        errors.append(
            f"{info.platform or 'Cluster'} cloud login failed — fix this before selecting components. "
            f"{cloud_detail}"
        )
    else:
        warnings.append(f"Cloud ({info.platform}): {cloud_detail}")

    for tool, reason in (
        ("jq", "required by the GPU metrics script"),
        ("htpasswd", "required for bcrypt passwords in user scripts"),
        ("openssl", "required for random bucket suffixes in Loki/ACM"),
    ):
        if not shutil.which(tool):
            errors.append(f"{tool} not installed locally — {reason}.")

    return {"ok": len(errors) == 0, "errors": errors, "warnings": warnings}
