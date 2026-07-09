#!/usr/bin/env bash
# Shared helpers for OpenShift Reproducer Toolkit install scripts.
# shellcheck shell=bash

if [ -n "${OCP_TOOLKIT_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
OCP_TOOLKIT_COMMON_LOADED=1

set -euo pipefail

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

die_oc() {
  local msg="$1"
  shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: ${msg}" >&2
    echo "  Command: $*" >&2
    echo "  Output:" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "$out"
}

toolkit_bucket_key() {
  local key=""
  if [ -n "${OCP_TOOLKIT_KERBEROS:-}" ]; then
    key=$(echo "$OCP_TOOLKIT_KERBEROS" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 15)
    info "Bucket naming key: wizard kerberos '${key}' (OCP_TOOLKIT_KERBEROS)"
  else
    key=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 15)
    info "Bucket naming key: local hostname '${key}' (standalone script run)"
  fi
  [ -n "$key" ] || die "Bucket naming key is empty — provide OCP_TOOLKIT_KERBEROS in the wizard or use a valid hostname."
  echo "$key"
}

require_aws_credentials() {
  require_command aws
  local creds="${HOME}/.aws/credentials"
  [ -f "$creds" ] || die "AWS credentials missing at ~/.aws/credentials — run: aws configure"

  local id secret
  id=$(aws configure get aws_access_key_id 2>/dev/null || true)
  secret=$(aws configure get aws_secret_access_key 2>/dev/null || true)
  if [ -z "$id" ] || [ -z "$secret" ]; then
    die "AWS credentials file exists but access key or secret is empty — run: aws configure"
  fi

  local out rc=0
  out=$(aws sts get-caller-identity 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "AWS authentication failed (aws sts get-caller-identity). Check keys, expiry, and IAM permissions.

${out}"
  fi
  info "AWS authenticated: $(echo "$out" | head -n 1)"
}

require_gcp_credentials() {
  local cred_file
  cred_file=$(ls "${HOME}/.gcp/"*.json 2>/dev/null | head -n 1 || true)
  [ -n "$cred_file" ] && [ -f "$cred_file" ] || die "GCP service-account JSON not found in ~/.gcp/ — add a key file there."

  if command -v gcloud >/dev/null 2>&1; then
    local out rc=0
    out=$(gcloud auth activate-service-account --key-file="$cred_file" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      die "GCP service account activation failed for ${cred_file}:

${out}"
    fi
    out=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>&1 | head -n 1 || true)
    [ -n "$out" ] || die "GCP has no active account after activating ${cred_file}."
    info "GCP authenticated: ${out} (key: $(basename "$cred_file"))"
  elif command -v gsutil >/dev/null 2>&1; then
    warn "gcloud not found — using gsutil only; install Google Cloud SDK for full validation."
    info "GCP key file: ${cred_file}"
  else
    die "Neither gcloud nor gsutil found — install Google Cloud SDK for GCP clusters."
  fi
  echo "$cred_file"
}

_on_err() {
  local line="${1:-?}"
  echo "ERROR: Script failed at line ${line} (exit code $?)" >&2
  exit 1
}
trap '_on_err $LINENO' ERR

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "'${cmd}' is required but not installed."
}

require_oc() {
  require_command oc
  if ! oc whoami >/dev/null 2>&1; then
    die "Not logged in to OpenShift. Run 'oc login' as cluster-admin first."
  fi
  info "OpenShift session: $(oc whoami) @ $(oc whoami --show-server)"
}

require_cluster_admin() {
  require_oc
  if ! oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
    die "cluster-admin privileges are required for this script."
  fi
}

cluster_platform() {
  oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || true
}

require_platform_aws() {
  local platform
  platform=$(cluster_platform)
  [ "$platform" = "AWS" ] || die "This script requires an AWS cluster (detected: ${platform:-unknown})."
}

require_platform_aws_or_gcp() {
  local platform
  platform=$(cluster_platform)
  case "$platform" in
    AWS|GCP) info "Cluster platform: $platform" ;;
    *) die "Unsupported platform '${platform:-unknown}'. Expected AWS or GCP." ;;
  esac
}

# wait_for_cmd <description> <timeout_seconds> <interval> -- command...
wait_for_cmd() {
  local desc="$1" timeout_sec="$2" interval="$3"
  shift 3
  local elapsed=0 status_line=""
  info "Waiting for ${desc} (timeout ${timeout_sec}s)..."
  while ! "$@" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      die "Timeout waiting for ${desc} after ${timeout_sec}s. Last status: ${status_line:-unknown}"
    fi
    status_line=$("$@" 2>&1 | head -n 1 || true)
    echo "  > Still waiting for ${desc} (${elapsed}s)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  info "Ready: ${desc}"
}

confirm_or_abort() {
  local prompt="${1:-Proceed?}"
  if [ "${OCP_TOOLKIT_AUTO_YES:-}" = "1" ]; then
    info "Auto-confirmed (${prompt})"
    return 0
  fi
  local reply=""
  read -r -p "${prompt} (Yes/No): " reply
  if [[ ! "$reply" =~ ^[Yy](es)?$ ]]; then
    info "Aborted by user."
    exit 0
  fi
}

cluster_ocp_version() {
  oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true
}

# OCP 4.19+ unified console — Developer perspective is off by default (Red Hat docs).
ocp_needs_developer_perspective_patch() {
  local ver="${1:-$(cluster_ocp_version)}"
  local minor
  minor=$(echo "$ver" | sed -n 's/^4\.\([0-9][0-9]*\).*/\1/p')
  [ -n "$minor" ] && [ "$minor" -ge 19 ]
}

maybe_enable_developer_perspective() {
  if [ "${OCP_TOOLKIT_ENABLE_DEV_VIEW:-}" != "1" ]; then
    return 0
  fi

  local ver
  ver=$(cluster_ocp_version)
  if [ -z "$ver" ]; then
    warn "Developer console perspective was requested but cluster version could not be read — skipping patch."
    return 0
  fi

  if ! ocp_needs_developer_perspective_patch "$ver"; then
    echo "ℹ️  Developer perspective: skipped patch on OCP ${ver} (4.18 and earlier already include Developer view)."
    return 0
  fi

  info "OCP ${ver} (4.19+) — enabling Developer perspective in the web console..."
  oc patch console.operator.openshift.io/cluster --type=merge \
    -p '{"spec":{"customization":{"perspectives":[{"id":"dev","visibility":{"state":"Enabled"}}]}}}'
  info "Developer perspective enabled (console pod may take a minute to refresh)."
}
