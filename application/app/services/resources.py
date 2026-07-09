from app.config import (
    COMPONENT_RESOURCES,
    WORKER_INSTANCE_CPU,
    WORKER_INSTANCE_DEFAULT,
    WORKER_INSTANCE_MEMORY_GI,
)
from app.services.cluster import ClusterInfo


def _find_worker_machineset_name() -> str | None:
    import json
    import subprocess

    result = subprocess.run(
        ["oc", "get", "machineset", "-n", "openshift-machine-api", "-o", "json"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        if "worker" in name and "gpu" not in name:
            return name
    items = data.get("items", [])
    return items[0]["metadata"]["name"] if items else None


def estimate_resources(
    info: ClusterInfo,
    selected: dict[str, bool],
) -> dict:
    if not info.connected:
        return {"ok": False, "error": "Not connected to a cluster."}

    required_cpu = 0.0
    required_mem = 0.0
    items: list[dict] = []
    warnings: list[str] = []

    if selected.get("users"):
        selected_users = True
    else:
        selected_users = False

    worker_ms_name = _find_worker_machineset_name()

    for key, enabled in selected.items():
        if not enabled or key not in COMPONENT_RESOURCES:
            continue

        spec = COMPONENT_RESOURCES[key]
        if spec.get("requires_loki") and not selected.get("loki"):
            continue
        if spec.get("aws_only") and info.platform != "AWS":
            warnings.append(f"{spec['label']} requires an AWS cluster (detected: {info.platform or 'unknown'}).")
            continue

        cpu = spec["cpu_cores"]
        mem = spec["memory_gi"]
        required_cpu += cpu
        required_mem += mem
        items.append(
            {
                "key": key,
                "label": spec["label"],
                "cpu_cores": cpu,
                "memory_gi": mem,
                "extra_nodes": spec.get("extra_nodes", 0),
            }
        )

    available_cpu = info.total_cpu
    available_mem = info.total_memory_gi

    # Reserve ~15% for system overhead on workers
    usable_cpu = available_cpu * 0.85
    usable_mem = available_mem * 0.85

    cpu_short = max(0.0, required_cpu - usable_cpu)
    mem_short = max(0.0, required_mem - usable_mem)
    sufficient = cpu_short == 0 and mem_short == 0

    extra_workers = 0
    if not sufficient:
        by_cpu = int(cpu_short / (WORKER_INSTANCE_CPU * 0.85)) + (1 if cpu_short % (WORKER_INSTANCE_CPU * 0.85) > 0 else 0)
        by_mem = int(mem_short / (WORKER_INSTANCE_MEMORY_GI * 0.85)) + (1 if mem_short % (WORKER_INSTANCE_MEMORY_GI * 0.85) > 0 else 0)
        extra_workers = max(by_cpu, by_mem, 1)

    gpu_extra = 0
    if selected.get("gpu") and info.platform == "AWS":
        gpu_extra = COMPONENT_RESOURCES["gpu"].get("extra_nodes", 2)

    return {
        "ok": True,
        "sufficient": sufficient,
        "platform": info.platform,
        "available": {
            "cpu_cores": round(usable_cpu, 2),
            "memory_gi": round(usable_mem, 2),
            "worker_count": len(info.worker_nodes),
        },
        "required": {
            "cpu_cores": round(required_cpu, 2),
            "memory_gi": round(required_mem, 2),
        },
        "shortfall": {
            "cpu_cores": round(cpu_short, 2),
            "memory_gi": round(mem_short, 2),
        },
        "recommended_extra_workers": extra_workers,
        "gpu_extra_nodes": gpu_extra,
        "worker_machineset": worker_ms_name,
        "scale_assumption": (
            f"Shortfall uses {WORKER_INSTANCE_DEFAULT} sizing ({WORKER_INSTANCE_CPU} CPU, "
            f"{WORKER_INSTANCE_MEMORY_GI} Gi per node) to estimate how many workers to add."
        ),
        "scale_method": (
            "Add worker nodes increases the replica count on your existing worker MachineSet "
            "in openshift-machine-api (same EC2/instance type as current workers)."
        ),
        "components": items,
        "warnings": warnings,
        "selected_users": selected_users,
    }
