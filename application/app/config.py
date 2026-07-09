from pathlib import Path

# application/ — wizard root
ROOT_DIR = Path(__file__).resolve().parent.parent
# Repo root — shell scripts live here (siblings of application/)
REPO_ROOT = ROOT_DIR.parent
SCRIPTS_DIR = REPO_ROOT
HOST = "127.0.0.1"
PORT = 8765

SCRIPT_MAP = {
    "loki": SCRIPTS_DIR / "loki-install-aws-gcp-loki-script",
    "users_basic": SCRIPTS_DIR / "setup-users+redadmin.sh",
    "users_loki": SCRIPTS_DIR / "setup_users+loki_alerting.sh",
    "acm": SCRIPTS_DIR / "acm_acmobserve_aws_gcp.sh",
    "gpu": SCRIPTS_DIR / "provision-gpu-and-metrics.sh",
}

# Approximate allocatable headroom required on existing worker nodes (not GPU nodes).
COMPONENT_RESOURCES = {
    "loki": {"cpu_cores": 2.0, "memory_gi": 8.0, "label": "Loki logging stack"},
    "loki_alerting": {
        "cpu_cores": 1.0,
        "memory_gi": 4.0,
        "label": "Per-user Loki log alerting (aaa–zzz)",
        "requires_loki": True,
    },
    "users": {"cpu_cores": 1.0, "memory_gi": 4.0, "label": "HTPasswd users (aaa–zzz + redadmin)"},
    "acm": {"cpu_cores": 6.0, "memory_gi": 24.0, "label": "ACM + Observability"},
    "gpu": {
        "cpu_cores": 0.0,
        "memory_gi": 0.0,
        "label": "AWS GPU nodes (2× g4dn.xlarge)",
        "aws_only": True,
        "extra_nodes": 2,
    },
}

WORKER_INSTANCE_DEFAULT = "m5.2xlarge"
WORKER_INSTANCE_CPU = 8
WORKER_INSTANCE_MEMORY_GI = 32
