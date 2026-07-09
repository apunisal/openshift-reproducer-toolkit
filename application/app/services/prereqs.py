import os
import shutil
import subprocess
from pathlib import Path

from app.services.cloud_creds import validate_aws, validate_gcp


def _which(cmd: str) -> str | None:
    return shutil.which(cmd)


def _run_version(cmd: list[str]) -> str | None:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if result.returncode == 0:
            return (result.stdout or result.stderr).strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def check_prerequisites() -> dict:
    checks: list[dict] = []

    def add(name: str, ok: bool, detail: str, *, required: bool = True, group: str = "core"):
        checks.append(
            {
                "name": name,
                "ok": ok,
                "detail": detail,
                "required": required,
                "group": group,
            }
        )

    python_ok = _which("python3") is not None
    add(
        "python3",
        python_ok,
        _run_version(["python3", "--version"]) or "Not found — required to run this wizard",
    )

    oc_ok = _which("oc") is not None
    add(
        "oc CLI",
        oc_ok,
        _run_version(["oc", "version", "--client"]) or "Not found — required for cluster access",
    )

    for tool, why in (
        ("jq", "GPU script and JSON helpers"),
        ("htpasswd", "bcrypt password generation for user scripts"),
        ("openssl", "random bucket suffixes for Loki/ACM"),
    ):
        found = _which(tool) is not None
        add(
            tool,
            found,
            f"Installed ({why})" if found else f"Not found — required: {why}",
        )

    aws_ok, aws_detail = validate_aws()
    add(
        "AWS CLI + login",
        aws_ok,
        aws_detail,
        required=False,
        group="cloud",
    )

    gcp_ok, gcp_detail = validate_gcp()
    add(
        "GCP credentials + login",
        gcp_ok,
        gcp_detail,
        required=False,
        group="cloud",
    )

    core_ok = all(c["ok"] for c in checks if c["required"])
    cloud_ok = aws_ok or gcp_ok

    summary: list[str] = []
    if not core_ok:
        summary.append("Install all missing core tools before continuing.")
    if not aws_ok:
        summary.append(f"AWS not ready: {aws_detail}")
    if not gcp_ok:
        summary.append(f"GCP not ready: {gcp_detail}")
    if core_ok and not cloud_ok:
        summary.append(
            "Fix AWS or GCP login before connecting — clusters in this toolkit use cloud storage."
        )
    elif core_ok and cloud_ok:
        parts = []
        if aws_ok:
            parts.append("AWS")
        if gcp_ok:
            parts.append("GCP")
        summary.append(f"Core tools OK. Cloud ready: {', '.join(parts)}.")

    # Step 1: core tools only. Cloud is validated again at connect for the cluster platform.
    ready = core_ok

    return {
        "ready": ready,
        "core_ok": core_ok,
        "cloud_ok": cloud_ok,
        "aws_ok": aws_ok,
        "gcp_ok": gcp_ok,
        "checks": checks,
        "platform": _detect_os(),
        "summary": " ".join(summary),
    }


def _detect_os() -> str:
    try:
        import platform

        system = platform.system().lower()
        if system == "darwin":
            return "macOS"
        if system == "linux":
            if Path("/etc/redhat-release").exists():
                return "Linux (RHEL-family)"
            if Path("/etc/fedora-release").exists():
                return "Linux (Fedora)"
            return "Linux"
        return platform.platform()
    except Exception:
        return os.uname().sysname if hasattr(os, "uname") else "unknown"
