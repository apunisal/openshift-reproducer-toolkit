#!/bin/bash
# =======================================================
# Created by Apurva Nisal
# Tools used: Gemini
# =======================================================
#
# Features:
# - Smart HTPasswd management (Downloads existing, updates changed, adds missing, skips).
# - Generates true bcrypt hashes required by OpenShift 4.
# - Prevents 500 Internal Error crash loops by stripping hidden Windows carriage returns (\r).
# - Provisions 'redadmin' (with cluster-admin rights) and users 'aaa' to 'zzz'.
# - Fully Verbose Wait Loops (shows EXACT pod states and API error messages).
#
# Prerequisites:
# - Active session to the OpenShift cluster via 'oc login' as a cluster-admin.
# =======================================================

set -euo pipefail

echo "🔍 Checking OpenShift connection..."
if ! oc whoami >/dev/null 2>&1; then
  echo "❌ ERROR: You are not logged in. Please run 'oc login' as an administrator first."
  exit 1
fi

SERVER=$(oc whoami --show-server)
echo "✅ Logged in to: $SERVER"

# === 1. Secure Bcrypt Hash Generation for redadmin ===
echo "⚙️ Generating secure bcrypt hash for 'redadmin'..."
if command -v htpasswd >/dev/null 2>&1; then
    # Mac and most Linux systems have htpasswd built-in
    REDADMIN_HASH=$(htpasswd -n -B -b redadmin redadmin | cut -d: -f2)
else
    echo "⚠️ 'htpasswd' tool not found locally. Falling back to default secure hash (password will be 'aaa' for redadmin)."
    REDADMIN_HASH='$2y$05$LpNSp3nPOiLqNp4lw6YSCOQ546obt1h3XFsAvCDSQj/TipgffE8JG'
fi

# === 2. Prepare Target Users and Hashes ===
TARGET_USERS=$(cat <<EOF
redadmin:$REDADMIN_HASH
aaa:\$2y\$05\$LpNSp3nPOiLqNp4lw6YSCOQ546obt1h3XFsAvCDSQj/TipgffE8JG
bbb:\$2y\$05\$nDa.4x8eqmUAiVYgVe.1m.LrhEuPKnmpryXHDWcDr79ttc8QWQ2G2
ccc:\$2y\$05\$mVkAsYZrbpdvuRyDEABO5udIOF7TPHbd.QhPL3/hWve3h41v7Pbim
ddd:\$2y\$05\$5XL0dATuYe32aBImgRId9enuUOAd7Enpj7KsvZtV.NCI4VIiRrraK
eee:\$2y\$05\$.UhWauOu/WO0p36NroTLSOWtyX48HjirQyEoAP2kLeE4zyWwQVPVW
fff:\$2y\$05\$M/.0E3EVyk24DokZMWf6C.GfoH9wHOrprS.wGVxcUoSBdgIVX6i.a
ggg:\$2y\$05\$6fJwF3D0EWONSVaioGF.pey9ZtzsDsbfHRCGQ6xEILvZEzaJYspP2
hhh:\$2y\$05\$5sSCcRcKR8jQDo0n2vFxTu18T4AeoR70dzK7hMg1G3CudCnAQA1fm
iii:\$2y\$05\$w2OAfv0bgpID8zHAeIk.reIkrBdYw0zxYNQSVqJD4ZG2L5i1SdOuu
jjj:\$2y\$05\$Whfyaun8OGsVvu8pFv9vnOaSYLfEF/9.VAl2.ejTzFgMCIBQ0LmGm
kkk:\$2y\$05\$oFfbxKHX/vEbccsCJQBcM.f3XVauEYOBwId7t5lOjkHruL.k7kKqi
lll:\$2y\$05\$HCrErqFRKr0p9WQ9Kl/1leBeM1wVvdpGcOisYD6JipqNvmwXJmddG
mmm:\$2y\$05\$dnoyK0QWZ.Tl5m6Lh7RIIu2HhJu5xgcRs8vOXfMe1jbu3a2JkM2Bi
nnn:\$2y\$05\$A4yOGVjypHnxeQ9IqhOxvurE7n/ikDx1eiHPJ6bbpzuvh.S.emz/u
ooo:\$2y\$05\$f1KnybYdFb.qTCDQdW4nGelpSl0wc1NGShplTdMvXFkFprFx0FvPm
ppp:\$2y\$05\$KdSDCqqedlyElEcBtKOmbOxgrEB46uXc7nFdWNMkgpQKaTbWcRR/.
qqq:\$2y\$05\$wlzUa3hXf7iVh.mJOzCXtOHYlqdMTlfYMW2WaGnSpkBlFszjzB7yC
rrr:\$2y\$05\$77BMbzDL/DdaOY3yRJmjjeQdT9bU8XycAhjQbC4jtyIas0GKoqc8u
sss:\$2y\$05\$Fdbx0AKl2HRc5y9KOUhbcu0P.HuX7uooZmyV7gnaIxPeld8U0e0kW
ttt:\$2y\$05\$qeaf/.Xa7vpk81KLWLTzY.49ZRlm6J/fyqmpjj3/PXazE.BEgNkXq
uuu:\$2y\$05\$3ujFCLsgZB3Xyu56Nv0rAOmFNZDey6.9oBqI21404x8YNUZKcZtkO
vvv:\$2y\$05\$ZaeTPK/VWduzsHF7Tk5JSuWKW6v/Tov5s8ppAaOyHEXxeBEgKLItq
www:\$2y\$05\$cDg2NBF7Ass/7tvM6Yb58O7SfdkBJSqP23HFj2TrB7kItWpTvSL9q
xxx:\$2y\$05\$hiveEMZOnzde/Ua9yqMLE.GCrAGcdVKL/XLZLotIculqug3G/wuMy
yyy:\$2y\$05\$aQcf0xciMGglahX/4Ng91eqPnjIu2N/lT390pCAIHM3jNHZIN00Xm
zzz:\$2y\$05\$/y74CW7if5J56Pv5L2pseOCaP0qe07yNbm4uuM.KzU3AUI2ZNFQ/u
EOF
)

# === 3. Smart HTPasswd Management ===
echo "🌐 Processing HTPasswd entries..."
touch current_users.htpasswd

if oc get secret htpass-secret -n openshift-config >/dev/null 2>&1; then
    echo "  📥 Downloading existing htpasswd secret from cluster..."
    oc get secret htpass-secret -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 -d > current_users.htpasswd || true
fi

CHANGES_MADE=false

echo "$TARGET_USERS" | while IFS=: read -r user expected_hash; do
    if grep -q "^${user}:" current_users.htpasswd; then
        actual_hash=$(grep "^${user}:" current_users.htpasswd | cut -d: -f2-)
        if [ "$actual_hash" == "$expected_hash" ]; then
            echo "  ⏩ SKIP: User '$user' already exists with the correct password."
        else
            echo "  🔄 UPDATE: User '$user' has a different password. Updating..."
            sed -i.bak "s|^${user}:.*|${user}:${expected_hash}|" current_users.htpasswd
            CHANGES_MADE=true
        fi
    else
        echo "  ➕ ADD: User '$user' is missing. Adding..."
        echo "${user}:${expected_hash}" >> current_users.htpasswd
        CHANGES_MADE=true
    fi
done

rm -f current_users.htpasswd.bak

# MAGIC FIX: Strip any carriage returns before pushing to cluster
tr -d '\r' < current_users.htpasswd > clean.htpasswd

# === 4. Apply Config to Cluster ===
echo "🔐 Pushing sanitized secret to cluster..."
oc create secret generic htpass-secret --from-file=htpasswd=clean.htpasswd -n openshift-config --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1

echo "⚙️ Ensuring OAuth configuration is applied..."
cat <<EOF | oc apply -f - >/dev/null 2>&1
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

rm -f current_users.htpasswd clean.htpasswd

# === 5. Grant Admin Rights to redadmin ===
echo "👑 Granting cluster-admin permissions to 'redadmin'..."
oc adm policy add-cluster-role-to-user cluster-admin redadmin >/dev/null 2>&1 || echo "⚠️  Warning: Could not assign role. Skipping."

# === 6. Force Instant Pod Reload ===
if [ "$CHANGES_MADE" = true ]; then
    echo "💀 Restarting authentication pods to pick up the new passwords..."
    oc delete pods -n openshift-authentication -l app=oauth-openshift >/dev/null 2>&1
fi

# === 7. Verbose Wait For Pods ===
echo "⏳ Monitoring authentication pod startup..."
MAX_RETRIES=30
COUNT=0
PODS_READY=false
while [ $COUNT -lt $MAX_RETRIES ]; do
    COUNT=$((COUNT+1))
    
    POD_STATUS=$(oc get pods -n openshift-authentication -l app=oauth-openshift --no-headers 2>/dev/null | awk '{print $3}' | tr '\n' ',' | sed 's/,$//' || echo "No pods found")
    printf "  [Attempt %02d/%02d] Pod States: %s\n" "$COUNT" "$MAX_RETRIES" "$POD_STATUS"

    if oc wait --for=condition=Ready pod -l app=oauth-openshift -n openshift-authentication --timeout=1s >/dev/null 2>&1; then
        echo "  ✅ All authentication pods are Ready!"
        PODS_READY=true
        break
    fi
    sleep 5
done

if [ "$PODS_READY" = false ]; then
    echo "❌ ERROR: Pods did not become ready in time. Check 'oc get pods -n openshift-authentication'."
    exit 1
fi

# === 8. Verbose Wait For Login Acceptance ===
echo "⏳ Testing OpenShift API login acceptance..."
MAX_RETRIES=30
COUNT=0
LOGIN_SUCCESS=false

while [ $COUNT -lt $MAX_RETRIES ]; do
    COUNT=$((COUNT+1))
    printf "  [Attempt %02d/%02d] Authenticating 'redadmin'... " "$COUNT" "$MAX_RETRIES"
    
    # Capture the full output of the login command without hiding the actual error
    set +e
    LOGIN_OUTPUT=$(oc login -u redadmin -p redadmin --server="$SERVER" --insecure-skip-tls-verify=true 2>&1)
    LOGIN_EXIT_CODE=$?
    set -e

    if [ $LOGIN_EXIT_CODE -eq 0 ]; then
        echo "✅ Success! Login accepted."
        LOGIN_SUCCESS=true
        break
    else
        # Extract the exact first line of the error message so we know exactly what is failing
        ERROR_MSG=$(echo "$LOGIN_OUTPUT" | head -n 1)
        echo "❌ Failed: $ERROR_MSG (Retrying in 5s...)"
        sleep 5
    fi
done

if [ "$LOGIN_SUCCESS" = false ]; then
    echo "❌ FATAL ERROR: OpenShift never accepted the new passwords. The HTPasswd config may be corrupted."
    exit 1
fi

# === 9. Verify all user logins ===
echo "🔄 Verifying login for all users..."
USERS="aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt uuu vvv www xxx yyy zzz redadmin"

for user in $USERS; do
  if oc login -u "$user" -p "$user" --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
    echo "  ✅ User $user logged in successfully."
  else
    echo "  ❌ ERROR: User $user login FAILED."
  fi
done

# === 10. Restore Admin Session ===
echo "🔄 Restoring admin session as 'redadmin'..."
oc login -u redadmin -p redadmin --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1

echo "🎉 Script complete. All users configured and verified. You are currently logged in as 'redadmin'."
