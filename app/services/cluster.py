import json
import re
import subprocess
from dataclasses import dataclass

_session_kerberos: str | None = None


def sanitize_kerberos(value: str) -> str:
    """S3-safe bucket key (lowercase alphanumeric, max 15 chars)."""
    cleaned = re.sub(r"[^a-z0-9]", "", value.lower())[:15]
    return cleaned or "user"


def get_session_kerberos() -> str | None:
    if not _session_kerberos:
        return None
    return sanitize_kerberos(_session_kerberos)


@dataclass
class NodeResources:
    name: str
    role: str
    cpu_cores: float
    memory_gi: float


@dataclass
class ClusterInfo:
    connected: bool
    server: str | None
    user: str | None
    infrastructure_name: str | None
    platform: str | None
    region: str | None
    worker_nodes: list[NodeResources]
    total_cpu: float
    total_memory_gi: float
    error: str | None = None


def _run_oc(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["oc", *args],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


def login(api_url: str, username: str, password: str, kerberos: str) -> dict:
    global _session_kerberos
    username = username.strip()
    kerberos = kerberos.strip()
    if not kerberos:
        return {"ok": False, "error": "Kerberos is required (used for S3 bucket names)."}
    if not username:
        return {"ok": False, "error": "Username is required."}

    api_url = api_url.strip().rstrip("/")
    if not api_url.startswith("https://"):
        api_url = f"https://{api_url}"

    result = _run_oc(
        [
            "login",
            api_url,
            f"-u={username}",
            f"-p={password}",
            "--insecure-skip-tls-verify=true",
        ]
    )
    if result.returncode != 0:
        msg = (result.stderr or result.stdout or "Login failed").strip()
        return {"ok": False, "error": msg}

    _session_kerberos = kerberos
    return {
        "ok": True,
        "server": api_url,
        "username": username,
        "kerberos": sanitize_kerberos(kerberos),
    }


def get_cluster_info() -> ClusterInfo:
    whoami = _run_oc(["whoami"])
    if whoami.returncode != 0:
        return ClusterInfo(
            connected=False,
            server=None,
            user=None,
            infrastructure_name=None,
            platform=None,
            region=None,
            worker_nodes=[],
            total_cpu=0,
            total_memory_gi=0,
            error="Not logged in. Connect to a cluster first.",
        )

    server = _run_oc(["whoami", "--show-server"]).stdout.strip()
    user = whoami.stdout.strip()
    infra = _run_oc(
        ["get", "infrastructure", "cluster", "-o", "jsonpath={.status.infrastructureName}"]
    ).stdout.strip() or None

    platform = _run_oc(
        ["get", "infrastructure", "cluster", "-o", "jsonpath={.status.platformStatus.type}"]
    ).stdout.strip() or None

    region = None
    if platform == "AWS":
        region = _run_oc(
            [
                "get",
                "infrastructure",
                "cluster",
                "-o",
                "jsonpath={.status.platformStatus.aws.region}",
            ]
        ).stdout.strip() or None
    elif platform == "GCP":
        region = _run_oc(
            [
                "get",
                "infrastructure",
                "cluster",
                "-o",
                "jsonpath={.status.platformStatus.gcp.region}",
            ]
        ).stdout.strip() or None

    nodes_json = _run_oc(["get", "nodes", "-o", "json"])
    workers: list[NodeResources] = []
    total_cpu = 0.0
    total_memory = 0.0

    if nodes_json.returncode == 0 and nodes_json.stdout.strip():
        data = json.loads(nodes_json.stdout)
        for item in data.get("items", []):
            labels = item.get("metadata", {}).get("labels", {})
            name = item.get("metadata", {}).get("name", "unknown")
            is_worker = "node-role.kubernetes.io/worker" in labels
            is_master = "node-role.kubernetes.io/master" in labels or "node-role.kubernetes.io/control-plane" in labels
            if is_master and not is_worker:
                continue

            alloc = item.get("status", {}).get("allocatable", {})
            cpu_raw = alloc.get("cpu", "0")
            mem_raw = alloc.get("memory", "0Ki")

            if cpu_raw.endswith("m"):
                cpu = float(cpu_raw[:-1]) / 1000.0
            else:
                cpu = float(cpu_raw)

            if mem_raw.endswith("Ki"):
                mem_gi = float(mem_raw[:-2]) / (1024 * 1024)
            elif mem_raw.endswith("Mi"):
                mem_gi = float(mem_raw[:-2]) / 1024
            elif mem_raw.endswith("Gi"):
                mem_gi = float(mem_raw[:-2])
            else:
                mem_gi = 0.0

            role = "worker" if is_worker else "other"
            workers.append(NodeResources(name=name, role=role, cpu_cores=cpu, memory_gi=mem_gi))
            total_cpu += cpu
            total_memory += mem_gi

    return ClusterInfo(
        connected=True,
        server=server,
        user=user,
        infrastructure_name=infra,
        platform=platform,
        region=region,
        worker_nodes=workers,
        total_cpu=round(total_cpu, 2),
        total_memory_gi=round(total_memory, 2),
    )


def cluster_info_to_dict(info: ClusterInfo) -> dict:
    return {
        "connected": info.connected,
        "server": info.server,
        "user": info.user,
        "bucket_user": get_session_kerberos(),
        "kerberos": get_session_kerberos(),
        "infrastructure_name": info.infrastructure_name,
        "platform": info.platform,
        "region": info.region,
        "worker_count": len(info.worker_nodes),
        "total_cpu": info.total_cpu,
        "total_memory_gi": info.total_memory_gi,
        "worker_nodes": [
            {
                "name": n.name,
                "role": n.role,
                "cpu_cores": n.cpu_cores,
                "memory_gi": round(n.memory_gi, 2),
            }
            for n in info.worker_nodes
        ],
        "error": info.error,
    }
