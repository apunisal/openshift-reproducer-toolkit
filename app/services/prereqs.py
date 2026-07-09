import os
import shutil
import subprocess
from pathlib import Path


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

    def add(name: str, ok: bool, detail: str, required: bool = True):
        checks.append(
            {
                "name": name,
                "ok": ok,
                "detail": detail,
                "required": required,
            }
        )

    python_ok = _which("python3") is not None
    add(
        "python3",
        python_ok,
        _run_version(["python3", "--version"]) or "Not found",
    )

    oc_path = _which("oc")
    oc_ok = oc_path is not None
    add("oc CLI", oc_ok, _run_version(["oc", "version", "--client"]) or "Not found")

    aws_cli = _which("aws")
    aws_creds = Path.home() / ".aws" / "credentials"
    aws_creds_ok = aws_creds.is_file()
    add(
        "AWS CLI + credentials",
        aws_cli is not None and aws_creds_ok,
        f"{_run_version(['aws', '--version']) or 'aws not found'}; credentials: {'found' if aws_creds_ok else 'missing ~/.aws/credentials'}",
        required=False,
    )

    gcp_dir = Path.home() / ".gcp"
    gcp_files = list(gcp_dir.glob("*.json")) if gcp_dir.is_dir() else []
    gcp_ok = len(gcp_files) > 0
    add(
        "GCP credentials",
        gcp_ok,
        f"Found {len(gcp_files)} key file(s) in ~/.gcp/" if gcp_ok else "No ~/.gcp/*.json found",
        required=False,
    )

    for tool in ("jq", "htpasswd", "openssl", "gcloud"):
        found = _which(tool) is not None
        add(
            tool,
            found,
            "Installed" if found else "Not found (may be needed for some options)",
            required=False,
        )

    required_ok = all(c["ok"] for c in checks if c["required"])
    return {
        "ready": required_ok,
        "checks": checks,
        "platform": _detect_os(),
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
