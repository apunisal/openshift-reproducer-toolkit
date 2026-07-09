import json
import os
import subprocess
import threading
import time
import uuid
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

from app.config import REPO_ROOT, ROOT_DIR, SCRIPT_MAP
from app.services import cluster
from app.services.preflight import run_preflight

# Max seconds per script (wizard will fail the step after this).
SCRIPT_TIMEOUT_SEC: dict[str, int] = {
    "loki-install-aws-gcp-loki-script": 3600,
    "setup-users+redadmin.sh": 1800,
    "setup_users+loki_alerting.sh": 3600,
    "acm_acmobserve_aws_gcp.sh": 5400,
    "provision-gpu-and-metrics.sh": 3600,
}
DEFAULT_SCRIPT_TIMEOUT_SEC = 3600


@dataclass
class JobState:
    id: str
    status: str = "pending"
    logs: list[str] = field(default_factory=list)
    current_step: str | None = None
    error: str | None = None
    steps_completed: int = 0
    steps_total: int = 0


_jobs: dict[str, JobState] = {}
_lock = threading.Lock()


def _append_log(job: JobState, line: str) -> None:
    with _lock:
        job.logs.append(line)


def build_execution_plan(selected: dict[str, bool]) -> list[tuple[str, Path]]:
    plan: list[tuple[str, Path]] = []

    if selected.get("loki"):
        plan.append(("Deploy Loki logging stack", SCRIPT_MAP["loki"]))

    if selected.get("loki_alerting"):
        plan.append(("Deploy per-user Loki log alerting", SCRIPT_MAP["users_loki"]))

    if selected.get("users"):
        plan.append(("Deploy HTPasswd users (aaa–zzz + redadmin)", SCRIPT_MAP["users_basic"]))

    if selected.get("acm"):
        plan.append(("Deploy ACM + Observability", SCRIPT_MAP["acm"]))

    if selected.get("gpu"):
        plan.append(("Deploy AWS GPU nodes + metrics", SCRIPT_MAP["gpu"]))

    return plan


def scale_workers(extra_count: int) -> dict:
    if extra_count < 1:
        return {"ok": False, "error": "extra_count must be at least 1"}

    list_ms = subprocess.run(
        [
            "oc",
            "get",
            "machineset",
            "-n",
            "openshift-machine-api",
            "-o",
            "json",
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if list_ms.returncode != 0:
        return {"ok": False, "error": list_ms.stderr or "Could not list MachineSets"}

    data = json.loads(list_ms.stdout)
    worker_ms = None
    for item in data.get("items", []):
        name = item["metadata"]["name"]
        if "worker" in name and "gpu" not in name:
            worker_ms = item
            break

    if worker_ms is None and data.get("items"):
        worker_ms = data["items"][0]

    if worker_ms is None:
        return {"ok": False, "error": "No worker MachineSet found"}

    ms_name = worker_ms["metadata"]["name"]
    current = int(worker_ms.get("spec", {}).get("replicas", 0))
    target = current + extra_count

    patch = subprocess.run(
        [
            "oc",
            "patch",
            "machineset",
            ms_name,
            "-n",
            "openshift-machine-api",
            "--type=merge",
            "-p",
            json.dumps({"spec": {"replicas": target}}),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if patch.returncode != 0:
        return {"ok": False, "error": patch.stderr or patch.stdout}

    return {
        "ok": True,
        "machineset": ms_name,
        "previous_replicas": current,
        "new_replicas": target,
        "message": f"Scaled {ms_name} from {current} to {target} workers. New nodes may take 10–15 minutes.",
    }


def _run_script(job: JobState, label: str, script_path: Path, kerberos: str, developer_view: bool) -> bool:
    job.current_step = label
    _append_log(job, f"\n{'=' * 60}\n▶ {label}\n   Script: {script_path.name}\n{'=' * 60}\n")
    _append_log(job, f"S3/GCS bucket key (kerberos): {kerberos}")

    if not script_path.is_file():
        _append_log(job, f"ERROR: Script not found: {script_path}")
        return False

    cmd = ["bash", str(script_path)]
    env = {
        **os.environ,
        "OCP_TOOLKIT_AUTO_YES": "1",
        "OCP_TOOLKIT_KERBEROS": kerberos,
        "OCP_TOOLKIT_ENABLE_DEV_VIEW": "1" if developer_view else "0",
    }
    timeout_sec = SCRIPT_TIMEOUT_SEC.get(script_path.name, DEFAULT_SCRIPT_TIMEOUT_SEC)

    proc = subprocess.Popen(
        cmd,
        cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env,
        stdin=subprocess.PIPE,
    )

    assert proc.stdin is not None
    if script_path.name == "provision-gpu-and-metrics.sh":
        proc.stdin.write("Yes\n")
    proc.stdin.close()

    assert proc.stdout is not None
    started = time.time()
    timed_out = False
    for line in proc.stdout:
        if time.time() - started > timeout_sec:
            timed_out = True
            proc.kill()
            _append_log(job, f"\n❌ Step timed out after {timeout_sec}s")
            break
        _append_log(job, line.rstrip("\n"))

    proc.wait()
    if timed_out:
        job.error = f"Timed out after {timeout_sec}s: {label}"
        return False

    if proc.returncode != 0:
        tail = job.logs[-8:]
        summary = "\n".join(tail) if tail else f"exit code {proc.returncode}"
        job.error = f"Failed at: {label}\n{summary}"
        _append_log(job, f"\n❌ Step failed with exit code {proc.returncode}")
        return False

    _append_log(job, f"\n✅ Completed: {label}\n")
    return True


def start_deployment(selected: dict[str, bool]) -> str:
    plan = build_execution_plan(selected)
    if not plan:
        raise ValueError("No components selected")

    kerberos = cluster.get_session_kerberos()
    if not kerberos:
        raise ValueError("Connect to a cluster first (kerberos is used for S3 bucket names).")

    info = cluster.get_cluster_info()
    preflight = run_preflight(selected, info.platform)
    if not preflight["ok"]:
        raise ValueError("\n".join(preflight["errors"]))
    for warning in preflight.get("warnings", []):
        _append_log(job, f"⚠️  Preflight note: {warning}")

    developer_view = bool(selected.get("developer_view"))

    job_id = str(uuid.uuid4())
    job = JobState(id=job_id, status="running", steps_total=len(plan))
    with _lock:
        _jobs[job_id] = job

    def _worker() -> None:
        for label, script in plan:
            ok = _run_script(job, label, script, kerberos, developer_view)
            if ok:
                job.steps_completed += 1
            else:
                job.status = "failed"
                job.error = f"Failed at step: {label}"
                return
        job.status = "completed"
        job.current_step = None
        _append_log(job, "\n🎉 All selected components deployed successfully.\n")

    threading.Thread(target=_worker, daemon=True).start()
    return job_id


def get_job(job_id: str) -> JobState | None:
    with _lock:
        return _jobs.get(job_id)


def stream_logs(job_id: str, offset: int = 0) -> Iterator[dict]:
    while True:
        job = get_job(job_id)
        if job is None:
            yield {"type": "error", "message": "Job not found"}
            break

        with _lock:
            new_lines = job.logs[offset:]
            current_offset = len(job.logs)
            payload = {
                "type": "update",
                "status": job.status,
                "current_step": job.current_step,
                "steps_completed": job.steps_completed,
                "steps_total": job.steps_total,
                "error": job.error,
                "lines": new_lines,
                "offset": current_offset,
            }

        yield payload
        offset = current_offset

        if job.status in ("completed", "failed"):
            break
        time.sleep(1)
