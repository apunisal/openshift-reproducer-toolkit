# OpenShift Reproducer Toolkit

Shell scripts to top up an existing OpenShift cluster on AWS or GCP, plus a local web wizard to run them.

## Repository layout

| Path | Description |
|------|-------------|
| **Root `*.sh` scripts** | Standalone install scripts (run directly or via the wizard) |
| **[`application/`](application/)** | Web wizard UI + FastAPI backend |

### Install scripts (repo root)

- `loki-install-aws-gcp-loki-script` — Loki logging stack
- `setup-users+redadmin.sh` — HTPasswd users `aaa`–`zzz` + `redadmin`
- `setup_users+loki_alerting.sh` — Users + Loki alerting demo
- `acm_acmobserve_aws_gcp.sh` — ACM + Observability
- `provision-gpu-and-metrics.sh` — AWS GPU nodes + DCGM dashboard

### Web wizard

See **[application/README.md](application/README.md)** for screenshots, prerequisites, and quick start.

```bash
git clone https://github.com/apunisal/openshift-reproducer-toolkit.git
cd openshift-reproducer-toolkit/application
./install.sh && ./start.sh
```

Open http://127.0.0.1:8765

## Author

**Apurva Nisal**
