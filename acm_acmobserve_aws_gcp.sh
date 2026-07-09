#!/bin/bash

# =======================================================
# Created by Apurva Nisal
# Tools used: Gemini
# =======================================================
#
# Features:
# - Announces the currently logged-in OpenShift cluster.
# - Dynamically detects the underlying cloud platform (AWS or GCP) and cluster region.
# - Automatically pulls credentials from standard local paths (~/.aws/credentials or ~/.gcp/osServiceAccount.json).
# - Finds and installs the latest Advanced Cluster Management (ACM) operator.
# - Deploys a MultiClusterHub instance and waits for it to become active.
# - Prepares OpenShift Observability by configuring Thanos object storage.
# - Dynamically creates S3 (AWS) or GCS (GCP) buckets named: acm-observe-<hostname>-<random-number>.
# - Resource-saving logic: Searches for and reuses existing empty buckets (matching the specific prefix) created within the last 1.5 days.
# - Dynamically detects and configures the default StorageClass for MultiClusterObservability PVCs.
# - Pipes all output to both the terminal and 'acm-install-logs.txt'.
#
# Prerequisites:
# - Active session to the OpenShift cluster via 'oc login'.
# - 'cluster-admin' privileges on the target cluster.
# - AWS CLI ('aws') or Google Cloud CLI ('gcloud') installed locally, depending on your target cloud.
# - Local credentials configured:
#     - AWS: ~/.aws/credentials (must contain a [default] profile with access keys).
#     - GCP: ~/.gcp/osServiceAccount.json (must contain a valid service account key).
# - 'python3' installed locally to ensure cross-platform timestamp parsing for the bucket reuse logic.
# =======================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ACM_NAMESPACE="open-cluster-management"
OBS_NAMESPACE="open-cluster-management-observability"
LOG_FILE="acm-install-logs.txt"

# 1. Main Function to wrap logic for tee
run_install() {
    echo "--- Starting Installation: $(date) ---"
    require_cluster_admin
    require_platform_aws_or_gcp

    # --- Announce Connected Cluster ---
    CURRENT_CLUSTER=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
    if [ -z "$CURRENT_CLUSTER" ]; then
        echo "Error: Could not determine cluster name. Are you logged in via 'oc login'?"
        exit 1
    fi
    echo "======================================================="
    echo "Script found logged in to cluster: $CURRENT_CLUSTER"
    echo "======================================================="

    # --- Dynamic Platform Detection ---
    echo "Detecting Cloud Platform..."
    PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null)
    
    if [ -z "$PLATFORM" ]; then
        echo "Error: Could not detect cloud platform."
        exit 1
    fi
    echo "Detected Platform: $PLATFORM"

    # --- Storage Class Detection ---
    echo "Detecting Default StorageClass..."
    DEFAULT_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
    
    if [ -z "$DEFAULT_SC" ]; then
        # Fallbacks if annotation is missing
        if [ "$PLATFORM" == "AWS" ]; then
            DEFAULT_SC="gp3" # fallback AWS
        elif [ "$PLATFORM" == "GCP" ]; then
            DEFAULT_SC="standard-csi" # fallback GCP
        else
            DEFAULT_SC="thin"
        fi
        echo "Warning: No default StorageClass annotated. Falling back to platform default: $DEFAULT_SC"
    else
        echo "Detected Default StorageClass: $DEFAULT_SC"
    fi

    # --- Credentials & Region Setup based on Platform ---
    if [ "$PLATFORM" == "AWS" ]; then
        AWS_CREDS_FILE="$HOME/.aws/credentials"
        if [ -f "$AWS_CREDS_FILE" ]; then
            echo "Extracting AWS credentials from $AWS_CREDS_FILE..."
            export AWS_ACCESS_KEY_ID=$(grep -A 4 '\[default\]' "$AWS_CREDS_FILE" | grep -i aws_access_key_id | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
            export AWS_SECRET_ACCESS_KEY=$(grep -A 4 '\[default\]' "$AWS_CREDS_FILE" | grep -i aws_secret_access_key | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
            
            if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
                echo "Error: Could not parse AWS credentials."
                exit 1
            fi
        else
            echo "Error: $AWS_CREDS_FILE not found."
            exit 1
        fi

        # Detect AWS Region
        CLUSTER_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null)
        export CLOUD_REGION="${CLUSTER_REGION:-us-east-2}"
        echo "AWS Region set to: $CLOUD_REGION based on cluster location."

    elif [ "$PLATFORM" == "GCP" ]; then
        GCP_CREDS_FILE="$HOME/.gcp/osServiceAccount.json"
        if [ ! -f "$GCP_CREDS_FILE" ]; then
            GCP_CREDS_FILE=$(ls "${HOME}/.gcp/"*.json 2>/dev/null | head -n 1 || true)
        fi
        
        if [ -n "$GCP_CREDS_FILE" ] && [ -f "$GCP_CREDS_FILE" ]; then
            echo "Found GCP credentials at $GCP_CREDS_FILE."
            
            gcloud auth activate-service-account --key-file="$GCP_CREDS_FILE" >/dev/null 2>&1
            PROJECT_ID=$(grep -o '"project_id": *"[^"]*"' "$GCP_CREDS_FILE" | cut -d'"' -f4)
            if [ -n "$PROJECT_ID" ]; then
                gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
            fi

            # Format JSON for Thanos Secret (add 4 spaces for YAML indentation)
            GCP_SA_JSON=$(sed 's/^/    /' "$GCP_CREDS_FILE")
        else
            echo "Error: GCP credentials not found at $GCP_CREDS_FILE."
            exit 1
        fi

        # Detect GCP Region dynamically 
        CLUSTER_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.gcp.region}' 2>/dev/null)
        export CLOUD_REGION="${CLUSTER_REGION:-us-east1}"
        echo "GCP Region detected as: $CLOUD_REGION based on cluster location."
    else
        echo "Error: Unsupported platform '$PLATFORM'. This script currently supports AWS and GCP."
        exit 1
    fi

    # Utility Functions
    resource_exists() {
        oc get "$1" "$2" -n "$3" >/dev/null 2>&1
    }

    wait_for_crd() {
        wait_for_cmd "CRD $1" "${2:-900}" 15 oc get crd "$1"
    }

    wait_for_mch_running() {
        local timeout_sec="${1:-1800}"
        local elapsed=0
        local interval=20
        info "Waiting for MultiClusterHub phase: Running (timeout ${timeout_sec}s)..."
        while true; do
            local phase
            phase=$(oc get mch multiclusterhub -n "$ACM_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
            if [ "$phase" = "Running" ]; then
                info "MultiClusterHub is Running"
                return 0
            fi
            if [ "$elapsed" -ge "$timeout_sec" ]; then
                die "Timeout waiting for MultiClusterHub Running (last phase: ${phase})"
            fi
            echo "  > MCH status: ${phase} (${elapsed}s elapsed)"
            sleep "$interval"
            elapsed=$((elapsed + interval))
        done
    }

    # 2. Strictly Get Latest ACM Channel
    echo "Fetching latest available ACM channel..."
    LATEST_CHANNEL=$(oc get packagemanifest advanced-cluster-management -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' | tr ' ' '\n' | sort -V | tail -n 1)
    
    if [ -z "$LATEST_CHANNEL" ]; then
        echo "Error: Could not determine the latest ACM channel."
        exit 1
    fi
    echo "Latest channel detected: $LATEST_CHANNEL"

    # 3. Namespace & Subscription
    if ! oc get ns "$ACM_NAMESPACE" >/dev/null 2>&1; then
        echo "Creating namespace $ACM_NAMESPACE"
        oc create ns "$ACM_NAMESPACE"
    fi

    if ! resource_exists "subscription" "advanced-cluster-management" "$ACM_NAMESPACE"; then
        echo "Applying Subscription..."
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operatorgroup
  namespace: $ACM_NAMESPACE
spec:
  targetNamespaces: ["$ACM_NAMESPACE"]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: $ACM_NAMESPACE
spec:
  channel: $LATEST_CHANNEL
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    fi

    # 4. Wait for CRD
    wait_for_crd "multiclusterhubs.operator.open-cluster-management.io"

    # 5. MultiClusterHub
    if ! resource_exists "multiclusterhub" "multiclusterhub" "$ACM_NAMESPACE"; then
        echo "Applying MultiClusterHub..."
        cat <<EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: $ACM_NAMESPACE
spec:
  localClusterName: local-cluster
EOF
        
        wait_for_mch_running 1800
    fi

    # 6. Observability Namespace
    if ! oc get ns "$OBS_NAMESPACE" >/dev/null 2>&1; then
        oc create ns "$OBS_NAMESPACE"
    fi

    # 7. Dynamic Object Storage Bucket Logic (AWS vs GCP)
    if ! resource_exists "secret" "thanos-object-storage" "$OBS_NAMESPACE"; then
        
        BUCKET_READY=false
        BUCKET_KEY=$(toolkit_bucket_key)
        BUCKET_PREFIX="acm-observe-${BUCKET_KEY}-"
        
        # Calculate time 1.5 days ago (129600 seconds)
        CURRENT_TIME=$(date +%s)
        CUTOFF_TIME=$((CURRENT_TIME - 129600))
        
        BUCKET_TO_USE=""

        echo "Checking for existing reusable empty buckets starting with '${BUCKET_PREFIX}' created within the last 1.5 days..."

        if [ "$PLATFORM" == "AWS" ]; then
            # Search for AWS buckets matching the exact prefix
            aws s3api list-buckets --query "Buckets[?starts_with(Name, '${BUCKET_PREFIX}')].[Name,CreationDate]" --output text | while read B_NAME B_DATE; do
                if [ -z "$B_NAME" ]; then continue; fi
                
                # Convert AWS creation date to epoch (using python to avoid cross-platform GNU/Mac date issues)
                B_TIME=$(python3 -c "from datetime import datetime; import sys; d=datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')); print(int(d.timestamp()))" "$B_DATE" 2>/dev/null)
                
                if [ -n "$B_TIME" ] && [ "$B_TIME" -ge "$CUTOFF_TIME" ]; then
                    # Check if bucket is empty
                    OBJ_COUNT=$(aws s3api list-objects-v2 --bucket "$B_NAME" --max-items 1 --query "length(Contents[])" --output text 2>/dev/null)
                    if [ "$OBJ_COUNT" == "None" ] || [ "$OBJ_COUNT" == "0" ]; then
                        echo "$B_NAME" > /tmp/found_bucket.txt
                        break
                    fi
                fi
            done

            if [ -f /tmp/found_bucket.txt ]; then
                BUCKET_TO_USE=$(cat /tmp/found_bucket.txt)
                rm -f /tmp/found_bucket.txt
            fi
            
            if [ -n "$BUCKET_TO_USE" ]; then
                echo "Found recent empty AWS S3 Bucket: $BUCKET_TO_USE. Reusing it."
                BUCKET_NAME="$BUCKET_TO_USE"
                BUCKET_READY=true
            else
                # Create a new bucket (prefix already includes the hyphen)
                BUCKET_NAME="${BUCKET_PREFIX}${RANDOM}"
                echo "Creating new AWS S3 Bucket: $BUCKET_NAME in region $CLOUD_REGION..."
                if [ "$CLOUD_REGION" == "us-east-1" ]; then
                    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$CLOUD_REGION"
                else
                    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$CLOUD_REGION" --create-bucket-configuration LocationConstraint="$CLOUD_REGION"
                fi
                [ $? -eq 0 ] && BUCKET_READY=true
            fi

            THANOS_CONFIG="type: s3
config:
  bucket: $BUCKET_NAME
  endpoint: s3.$CLOUD_REGION.amazonaws.com
  insecure: false
  access_key: $AWS_ACCESS_KEY_ID
  secret_key: $AWS_SECRET_ACCESS_KEY"

        elif [ "$PLATFORM" == "GCP" ]; then
            # Search for GCP buckets matching the exact prefix
            gcloud storage buckets list --format="value(name,timeCreated)" | grep "^${BUCKET_PREFIX}" | while read B_NAME B_DATE; do
                if [ -z "$B_NAME" ]; then continue; fi
                
                B_TIME=$(python3 -c "from datetime import datetime; import sys; d=datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')); print(int(d.timestamp()))" "$B_DATE" 2>/dev/null)
                
                if [ -n "$B_TIME" ] && [ "$B_TIME" -ge "$CUTOFF_TIME" ]; then
                    # Check if bucket is empty (if output is empty, bucket has no objects)
                    CONTENTS=$(gcloud storage ls "gs://${B_NAME}/" 2>/dev/null)
                    if [ -z "$CONTENTS" ]; then
                        echo "$B_NAME" > /tmp/found_bucket.txt
                        break
                    fi
                fi
            done

            if [ -f /tmp/found_bucket.txt ]; then
                BUCKET_TO_USE=$(cat /tmp/found_bucket.txt)
                rm -f /tmp/found_bucket.txt
            fi

            if [ -n "$BUCKET_TO_USE" ]; then
                echo "Found recent empty GCS Bucket: $BUCKET_TO_USE. Reusing it."
                BUCKET_NAME="$BUCKET_TO_USE"
                BUCKET_READY=true
            else
                # Create a new bucket (prefix already includes the hyphen)
                BUCKET_NAME="${BUCKET_PREFIX}${RANDOM}"
                echo "Creating new GCS Bucket: $BUCKET_NAME in region $CLOUD_REGION..."
                gcloud storage buckets create "gs://$BUCKET_NAME" --location="$CLOUD_REGION"
                [ $? -eq 0 ] && BUCKET_READY=true
            fi

            THANOS_CONFIG="type: GCS
config:
  bucket: $BUCKET_NAME
  service_account: |-
$GCP_SA_JSON"

        fi

        # Apply the secret
        if [ "$BUCKET_READY" = true ]; then
            echo "Creating Thanos secret for $PLATFORM (Bucket: $BUCKET_NAME)..."
            cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: $OBS_NAMESPACE
type: Opaque
stringData:
  thanos.yaml: |
$(echo "$THANOS_CONFIG" | sed 's/^/    /')
EOF
        else
            echo "Failed to prepare bucket. Exiting."
            exit 1
        fi
    fi

    # 8. MCO Deployment with Explicit StorageClass
    wait_for_crd "multiclusterobservabilities.observability.open-cluster-management.io"

    if ! resource_exists "multiclusterobservability" "observability" ""; then
        echo "Applying MultiClusterObservability using StorageClass: $DEFAULT_SC..."
        cat <<EOF | oc apply -f -
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  observabilityAddonSpec: {}
  storageConfig:
    storageClass: $DEFAULT_SC
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
EOF
    fi

    echo "--- Finished: $(date) ---"
}

# Invoke the function and pipe output to log; preserve real exit code for the wizard.
set -o pipefail
run_install 2>&1 | tee "$LOG_FILE"
exit "${PIPESTATUS[0]}"
