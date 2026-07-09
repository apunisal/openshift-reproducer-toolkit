#!/bin/bash
# =======================================================
# Created by Apurva Nisal
# Tools used: Gemini
# =======================================================
#
# Features:
# - Configures HTPasswd Identity Provider safely.
# - Idempotent execution (safe to run multiple times without breaking the cluster).
# - Enables User Workload Monitoring automatically.
# - Configures LokiStack to evaluate log-alerting rules.
# - Automatically provisions 26 test users (aaa to zzz) with dedicated namespaces.
# - Grants proper RBAC permissions so users can view their projects and alerts in the OpenShift UI.
# - Deploys a test application and a Loki AlertingRule for each user.
#
# Prerequisites:
# - Active session to the OpenShift cluster via 'oc login' as a cluster-admin.
# - The 'oc' CLI tool installed locally.
# =======================================================

set -euo pipefail

LOGFILE="openshift_setup_$(date +%F_%H-%M-%S).log"
FAILED_USERS="failed_users_$(date +%F_%H-%M-%S).txt"

echo "📝 Logging output to: $LOGFILE"

echo "🔍 Checking OpenShift connection..."
if ! oc whoami >/dev/null 2>&1; then
  echo "❌ You are not logged in. Please run 'oc login' as an administrator first."
  exit 1
fi

# === 1. Identity Provider (HTPasswd) ===
if ! oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].type}' 2>/dev/null | grep -q "HTPasswd"; then
    echo "🌐 Configuring HTPasswd Identity Provider..."
    
    # MAGIC FIX: tr -d '\r' strips hidden characters that cause the 500 crash error
    cat <<'EOF' | tr -d '\r' > users.htpasswd
aaa:$2y$05$LpNSp3nPOiLqNp4lw6YSCOQ546obt1h3XFsAvCDSQj/TipgffE8JG
bbb:$2y$05$nDa.4x8eqmUAiVYgVe.1m.LrhEuPKnmpryXHDWcDr79ttc8QWQ2G2
ccc:$2y$05$mVkAsYZrbpdvuRyDEABO5udIOF7TPHbd.QhPL3/hWve3h41v7Pbim
ddd:$2y$05$5XL0dATuYe32aBImgRId9enuUOAd7Enpj7KsvZtV.NCI4VIiRrraK
eee:$2y$05$.UhWauOu/WO0p36NroTLSOWtyX48HjirQyEoAP2kLeE4zyWwQVPVW
fff:$2y$05$M/.0E3EVyk24DokZMWf6C.GfoH9wHOrprS.wGVxcUoSBdgIVX6i.a
ggg:$2y$05$6fJwF3D0EWONSVaioGF.pey9ZtzsDsbfHRCGQ6xEILvZEzaJYspP2
hhh:$2y$05$5sSCcRcKR8jQDo0n2vFxTu18T4AeoR70dzK7hMg1G3CudCnAQA1fm
iii:$2y$05$w2OAfv0bgpID8zHAeIk.reIkrBdYw0zxYNQSVqJD4ZG2L5i1SdOuu
jjj:$2y$05$Whfyaun8OGsVvu8pFv9vnOaSYLfEF/9.VAl2.ejTzFgMCIBQ0LmGm
kkk:$2y$05$oFfbxKHX/vEbccsCJQBcM.f3XVauEYOBwId7t5lOjkHruL.k7kKqi
lll:$2y$05$HCrErqFRKr0p9WQ9Kl/1leBeM1wVvdpGcOisYD6JipqNvmwXJmddG
mmm:$2y$05$dnoyK0QWZ.Tl5m6Lh7RIIu2HhJu5xgcRs8vOXfMe1jbu3a2JkM2Bi
nnn:$2y$05$A4yOGVjypHnxeQ9IqhOxvurE7n/ikDx1eiHPJ6bbpzuvh.S.emz/u
ooo:$2y$05$f1KnybYdFb.qTCDQdW4nGelpSl0wc1NGShplTdMvXFkFprFx0FvPm
ppp:$2y$05$KdSDCqqedlyElEcBtKOmbOxgrEB46uXc7nFdWNMkgpQKaTbWcRR/.
qqq:$2y$05$wlzUa3hXf7iVh.mJOzCXtOHYlqdMTlfYMW2WaGnSpkBlFszjzB7yC
rrr:$2y$05$77BMbzDL/DdaOY3yRJmjjeQdT9bU8XycAhjQbC4jtyIas0GKoqc8u
sss:$2y$05$Fdbx0AKl2HRc5y9KOUhbcu0P.HuX7uooZmyV7gnaIxPeld8U0e0kW
ttt:$2y$05$qeaf/.Xa7vpk81KLWLTzY.49ZRlm6J/fyqmpjj3/PXazE.BEgNkXq
uuu:$2y$05$3ujFCLsgZB3Xyu56Nv0rAOmFNZDey6.9oBqI21404x8YNUZKcZtkO
vvv:$2y$05$ZaeTPK/VWduzsHF7Tk5JSuWKW6v/Tov5s8ppAaOyHEXxeBEgKLItq
www:$2y$05$cDg2NBF7Ass/7tvM6Yb58O7SfdkBJSqP23HFj2TrB7kItWpTvSL9q
xxx:$2y$05$hiveEMZOnzde/Ua9yqMLE.GCrAGcdVKL/XLZLotIculqug3G/wuMy
yyy:$2y$05$aQcf0xciMGglahX/4Ng91eqPnjIu2N/lT390pCAIHM3jNHZIN00Xm
zzz:$2y$05$/y74CW7if5J56Pv5L2pseOCaP0qe07yNbm4uuM.KzU3AUI2ZNFQ/u
EOF

    oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config --dry-run=client -o yaml | oc apply -f - >>"$LOGFILE" 2>&1
    
    oc apply -f - <<EOF >>"$LOGFILE" 2>&1
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: my_htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
EOF
    
    echo "⏳ Waiting for authentication operator to stabilize..."
    sleep 10 
    oc wait --for=condition=Progressing=False clusteroperator/authentication --timeout=5m >>"$LOGFILE" 2>&1 || true
else
    echo "ℹ️ OAuth HTPasswd already configured. Skipping."
fi

# === 2. Enable User Workload Monitoring ===
echo "📈 Checking User Workload Monitoring..."
set +e
UWM_CONFIG=$(oc get cm cluster-monitoring-config -n openshift-monitoring -o yaml 2>/dev/null)
set -e

if echo "$UWM_CONFIG" | grep -q "enableUserWorkload: true"; then
    echo "ℹ️ User Workload Monitoring already enabled. Skipping."
else
    if oc get cm cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
        oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}' >>"$LOGFILE" 2>&1
    else
        cat <<EOF | oc apply -f - >>"$LOGFILE" 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    fi
    echo "✅ Enabled User Workload Monitoring."
fi

# === 3. Configure LokiStack Rules ===
echo "⚙️ Configuring LokiStack..."
LOKISTACK_NAME=$(oc get lokistack -n openshift-logging -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "$LOKISTACK_NAME" ]; then
    oc patch lokistack "$LOKISTACK_NAME" -n openshift-logging --type merge -p \
      '{"spec":{"rules":{"enabled":true,"namespaceSelector":{"matchLabels":{"openshift.io/log-alerting":"true"}},"selector":{"matchLabels":{"openshift.io/log-alerting":"true"}}}}}' >>"$LOGFILE" 2>&1
    echo "✅ LokiStack patched."
fi

# === 4. Per-User Loop ===
USERS="aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt uuu vvv www xxx yyy zzz"

for user in $USERS; do
  PROJECT="ns-testapp-logalert-$user"
  if ! oc get project "$PROJECT" >/dev/null 2>&1; then
    oc new-project "$PROJECT" >>"$LOGFILE" 2>&1
  fi
  oc label namespace "$PROJECT" openshift.io/log-alerting='true' --overwrite >>"$LOGFILE" 2>&1

  cat <<EOF | oc apply -f - >>"$LOGFILE" 2>&1
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: project-admin-$user
  namespace: $PROJECT
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- kind: User
  name: $user
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: view-application-logs
  namespace: $PROJECT
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-logging-application-view
subjects:
- kind: User
  name: $user
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alert-view-$user
  namespace: $PROJECT
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: monitoring-rules-view
subjects:
- kind: User
  name: $user
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: testapp-logalerting
    openshift.io/log-alerting: 'true'
  name: testapp-logalerting
  namespace: $PROJECT
spec:
  replicas: 1
  selector:
    matchLabels:
      app: testapp-logalerting
  template:
    metadata:
      labels:
        app: testapp-logalerting
    spec:
      containers:
      - image: quay.io/rhobs/testapp-logalerting:latest
        imagePullPolicy: IfNotPresent
        name: testapp-logalerting
---
apiVersion: loki.grafana.com/v1
kind: AlertingRule
metadata:
  name: test-logging-alert-$user
  namespace: $PROJECT
  labels:
    openshift.io/log-alerting: 'true'
spec:
  groups:
  - interval: 1m
    name: Testloggingalert-$user
    rules:
    - alert: TestAppHighErrorRate-$user
      annotations:
        description: "Error rate check for $user"
        summary: "High error rate in $PROJECT"
      expr: >
        sum(rate({kubernetes_namespace_name="$PROJECT", kubernetes_pod_name=~"testapp-logalerting.*"} |= "error" [1m])) > 0.01
      for: 1m
      labels:
        severity: critical
  tenantID: application
EOF
done

echo "✅ All users processed."
echo "🎉 Script complete. Ready for team use."
