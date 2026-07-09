#!/bin/bash

# =======================================================
# Created by Apurva Nisal
# Tools used: Gemini
# =======================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- CONFIGURATION ---
GPU_INSTANCE_TYPE="g4dn.xlarge"
REPLICAS=2
NAMESPACE_API="openshift-machine-api"
GPU_NS="nvidia-gpu-operator"
NFD_NS="openshift-nfd"

echo "======================================================="
echo "🚀 OCP AWS GPU Node & Full Monitoring Automation Script"
echo "======================================================="

# --- SCRIPT SUMMARY & ACKNOWLEDGMENT ---
echo ""
echo "Before we begin, here is exactly what this script will do:"
echo "  1. Create MachineSet: Provisions new AWS EC2 instances with physical GPUs attached."
echo "  2. Install NFD Operator: Automatically detects hardware and applies the necessary PCI labels to nodes."
echo "  3. Install NVIDIA Operator: Deploys the official drivers, device plugins, and container toolkits."
echo "  4. Apply Custom Resources: Activates the operators and explicitly enables the metrics ServiceMonitor."
echo "  5. Enable User Workload Monitoring: Configures OpenShift Prometheus to scrape metrics from non-core namespaces."
echo "  6. Import Metrics Dashboard: Injects NVIDIA's official DCGM dashboard directly into the OpenShift Observe UI."
echo "  7. Deploy Test App: Spins up a continuous CUDA workload to wake up the GPU and verify functionality."
echo ""
echo "⚠️  PREREQUISITE: You must be logged into your AWS cluster via the CLI."
echo "   Example: oc login -u kubeadmin -p XXX --server=https://api.XXX:6443"
echo ""

confirm_or_abort "Should I go ahead?"

# Pre-flight Checks (Run after acknowledgment)
require_command jq
require_cluster_admin
require_platform_aws

echo ""
echo "🔍 PHASE 1: MachineSet Infrastructure"
echo "-------------------------------------------------------"

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
AZ=$(oc get machineset -n $NAMESPACE_API -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.placement.availabilityZone}')
NEW_MS_NAME="${INFRA_ID}-gpu-${AZ}"

if oc get machineset "$NEW_MS_NAME" -n "$NAMESPACE_API" &>/dev/null; then
    echo "✅ MachineSet '$NEW_MS_NAME' already exists. Skipping creation."
else
    echo "⏳ Creating GPU MachineSet: $NEW_MS_NAME"
    SOURCE_MS=$(oc get machineset -n $NAMESPACE_API -o name | head -n 1)
    
    oc get "$SOURCE_MS" -n "$NAMESPACE_API" -o json | jq "
      del(.metadata.selfLink, .metadata.uid, .metadata.creationTimestamp, .metadata.resourceVersion, .status) |
      .metadata.name = \"$NEW_MS_NAME\" |
      .spec.replicas = $REPLICAS |
      .spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$NEW_MS_NAME\" |
      .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$NEW_MS_NAME\" |
      .spec.template.spec.providerSpec.value.instanceType = \"$GPU_INSTANCE_TYPE\" |
      .spec.template.spec.metadata.labels[\"node-role.kubernetes.io/gpu\"] = \"\" |
      .spec.template.spec.metadata.labels[\"node-role.kubernetes.io/worker\"] = \"\"
    " > /tmp/gpu-machineset.json
    
    oc apply -f /tmp/gpu-machineset.json
    echo "✅ MachineSet provisioned successfully."
fi

echo "-------------------------------------------------------"
echo "🛠️  PHASE 2: Operator Deployment"
echo "-------------------------------------------------------"

manage_operator() {
    local ns=$1
    local pkg=$2
    local source=$3

    echo "Checking Operator: $pkg..."
    oc apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
EOF

    local current_csv=$(oc get sub "$pkg" -n "$ns" -o jsonpath='{.status.currentCSV}' 2>/dev/null)
    local csv_status=""
    if [ -n "$current_csv" ]; then csv_status=$(oc get csv "$current_csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null); fi

    # Auto-Remediation: Clean up broken installs
    if [[ "$csv_status" == "Failed" || ( -z "$current_csv" && $(oc get sub "$pkg" -n "$ns" 2>/dev/null) ) ]]; then
        echo "⚠️  Detected broken state for $pkg. Initiating deep clean..."
        oc delete sub "$pkg" -n "$ns" --ignore-not-found
        oc delete csv --all -n "$ns" --ignore-not-found
        oc delete installplan --all -n "$ns" --ignore-not-found
        oc delete operatorgroup --all -n "$ns" --ignore-not-found
        sleep 5
        csv_status="" 
    fi

    if [[ "$csv_status" == "Succeeded" ]]; then
        echo "✅ Operator $pkg is already installed and healthy."
    else
        echo "📦 Deploying Operator $pkg..."
        local target_channel=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
        if [ -z "$target_channel" ]; then target_channel="stable"; fi
        
        # Enforce OwnNamespace mode
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}-group
  namespace: ${ns}
spec:
  targetNamespaces:
  - ${ns}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${ns}
spec:
  channel: "${target_channel}"
  name: ${pkg}
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF
    fi
}

manage_operator "$NFD_NS" "nfd" "redhat-operators"
manage_operator "$GPU_NS" "gpu-operator-certified" "certified-operators"

echo "⏳ Waiting for Operator CSVs to reach 'Succeeded' phase (up to 3 minutes)..."
for i in {1..20}; do
    NFD_CSV=$(oc get sub nfd -n $NFD_NS -o jsonpath='{.status.currentCSV}' 2>/dev/null)
    GPU_CSV=$(oc get sub gpu-operator-certified -n $GPU_NS -o jsonpath='{.status.currentCSV}' 2>/dev/null)

    NFD_STATUS=$(oc get csv $NFD_CSV -n $NFD_NS -o jsonpath='{.status.phase}' 2>/dev/null)
    GPU_STATUS=$(oc get csv $GPU_CSV -n $GPU_NS -o jsonpath='{.status.phase}' 2>/dev/null)

    if [[ "$NFD_STATUS" == "Succeeded" && "$GPU_STATUS" == "Succeeded" ]]; then
        echo "✅ Both operators are successfully installed and active!"
        break
    fi
    echo "   Waiting... (Attempt $i/20) | NFD: ${NFD_STATUS:-Pending} | GPU: ${GPU_STATUS:-Pending}"
    sleep 10
done

if [[ "$NFD_STATUS" != "Succeeded" || "$GPU_STATUS" != "Succeeded" ]]; then
    die "GPU operators did not reach Succeeded (NFD: ${NFD_STATUS:-missing}, GPU: ${GPU_STATUS:-missing}). Check: oc get csv -n ${NFD_NS} and oc get csv -n ${GPU_NS}"
fi

echo "-------------------------------------------------------"
echo "⚡ PHASE 3: Apply NFD Instance & GPU ClusterPolicy"
echo "-------------------------------------------------------"

echo "Applying NodeFeatureDiscovery (NFD) Instance..."
oc apply -f - <<EOF
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec: {}
EOF

echo "Applying NVIDIA GPU ClusterPolicy (with ServiceMonitor enabled)..."
oc apply -f - <<EOF
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  driver:
    enabled: true
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
    serviceMonitor:
      enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  daemonsets:
    rollingUpdate:
      maxUnavailable: "1"
EOF
echo "✅ Core CRs applied."

echo "-------------------------------------------------------"
echo "📈 PHASE 4: Enabling User Workload Monitoring & Dashboard"
echo "-------------------------------------------------------"

echo "Enabling Prometheus User Workload Monitoring..."
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

if oc get configmap nvidia-dcgm-exporter-dashboard -n openshift-config-managed &>/dev/null; then
    echo "✅ GPU Monitoring Dashboard already exists. Skipping."
else
    echo "⬇️  Downloading and injecting DCGM Exporter Dashboard..."
    curl -sLfO https://github.com/NVIDIA/dcgm-exporter/raw/main/grafana/dcgm-exporter-dashboard.json
    oc create configmap nvidia-dcgm-exporter-dashboard -n openshift-config-managed --from-file=dcgm-exporter-dashboard.json
    oc label configmap nvidia-dcgm-exporter-dashboard -n openshift-config-managed "console.openshift.io/dashboard=true" --overwrite
    oc label configmap nvidia-dcgm-exporter-dashboard -n openshift-config-managed "console.openshift.io/odc-dashboard=true" --overwrite
    rm -f dcgm-exporter-dashboard.json
fi

echo "-------------------------------------------------------"
echo "🧪 PHASE 5: Deploying GPU Test Application"
echo "-------------------------------------------------------"

# Ensure namespace exists
oc apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: gpu-testing-app
EOF

echo "Deploying continuous GPU testing pod..."
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-continuous-app
  namespace: gpu-testing-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-monitor
  template:
    metadata:
      labels:
        app: gpu-monitor
    spec:
      containers:
        - name: gpu-looper
          image: nvcr.io/nvidia/cuda:12.2.0-base-ubuntu22.04
          command: ["/bin/sh", "-c"]
          args: ["while true; do echo 'Holding GPU...'; nvidia-smi; sleep 10; done"]
          resources:
            limits:
              nvidia.com/gpu: 1
EOF

echo "======================================================="
echo "🎉 DEPLOYMENT COMPLETE!"
echo "======================================================="
echo "What happens next:"
echo "1. AWS will take about 10 minutes to spin up the nodes."
echo "2. OpenShift will compile the NVIDIA drivers on the nodes automatically."
echo "3. The 'gpu-continuous-app' pod will grab a GPU once it is ready."
echo "4. Prometheus will scrape the metrics and display them in the OpenShift Console."
echo ""
echo "Monitor test pod logs:"
echo "   oc logs -l app=gpu-monitor -n gpu-testing-app -f"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo " ⚠️  PLEASE NOTE: METRICS WILL APPEAR 10-15 MIN AFTER POD CREATION"
echo ""
echo "    To view them, navigate in the OpenShift Web Console to:"
echo "    Observe > Dashboards > NVIDIA DCGM Exporter Dashboard"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""
