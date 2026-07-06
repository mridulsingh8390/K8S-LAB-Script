#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01b-install-trident.sh
# Installs Astra Trident (NetApp's CSI driver) into the AKS cluster, and
# configures its backend to talk to the Azure NetApp Files account created
# in 00b-azure-netapp-files.sh, so dynamic PersistentVolumeClaims can
# automatically provision real ANF volumes.
#
# Trident needs its own Azure credentials (an app registration / service
# principal with Contributor on the ANF account) - separate from AKS's own
# managed identity, since Trident calls the Azure NetApp Files management
# API directly, not through anything AKS already has access to.
#
# Run this AFTER 00b-azure-netapp-files.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./.infra-state.env

TRIDENT_APP_NAME="aks-lab-trident-sp"
TRIDENT_VERSION="24.10.0"   # check https://github.com/NetApp/trident/releases for the current release.
                            # NOTE: the Helm chart's --version flag expects the CHART version, which has
                            # historically tracked the Trident release version 1:1, but verify this against
                            # `helm search repo netapp-trident/trident-operator --versions` before relying
                            # on it - if the chart version has diverged from the software version by the
                            # time you run this, update this variable to match the chart version, not
                            # necessarily the software release number.

echo "############################################################"
echo "# 1/3: App registration (service principal) for Trident's Azure credentials"
echo "############################################################"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

TRIDENT_SP_JSON=$(az ad sp create-for-rbac --name "$TRIDENT_APP_NAME" \
  --role "Contributor" \
  --scopes "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}" \
  --query "{clientId:appId, clientSecret:password}" -o json)

TRIDENT_CLIENT_ID=$(echo "$TRIDENT_SP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['clientId'])")
TRIDENT_CLIENT_SECRET=$(echo "$TRIDENT_SP_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['clientSecret'])")

echo "Trident service principal client ID: $TRIDENT_CLIENT_ID"
echo "(client secret captured, not printed)"

echo "############################################################"
echo "# 2/3: Installing the Trident operator via Helm"
echo "############################################################"
helm repo add netapp-trident https://netapp.github.io/trident-helm-chart >/dev/null
helm repo update >/dev/null

helm upgrade --install trident netapp-trident/trident-operator \
  --create-namespace \
  --namespace trident \
  --version "$TRIDENT_VERSION"

echo "    ...waiting for the Trident operator to roll out"
kubectl wait --for=condition=Available deployment/trident-operator -n trident --timeout=180s
sleep 20
kubectl get pods -n trident

echo "############################################################"
echo "# 3/3: Trident backend configuration for Azure NetApp Files"
echo "############################################################"
kubectl create secret generic backend-tbc-anf-secret \
  --namespace trident \
  --from-literal=clientID="$TRIDENT_CLIENT_ID" \
  --from-literal=clientSecret="$TRIDENT_CLIENT_SECRET"

cat <<EOF | kubectl apply -f -
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: backend-tbc-anf
  namespace: trident
spec:
  version: 1
  storageDriverName: azure-netapp-files
  subscriptionID: "${SUBSCRIPTION_ID}"
  tenantID: "${TENANT_ID}"
  location: "${LOCATION}"
  serviceLevel: "${ANF_SERVICE_LEVEL}"
  credentials:
    name: backend-tbc-anf-secret
EOF

echo "    ...waiting for the backend to report Success"
sleep 20
kubectl get tridentbackendconfig -n trident

echo "==> StorageClass for dynamic ANF provisioning"
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azure-netapp-files
provisioner: csi.trident.netapp.io
parameters:
  backendType: "azure-netapp-files"
  fsType: "nfs"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

echo "============================================================"
echo "DONE."
echo "  Trident:            installed in the 'trident' namespace"
echo "  Backend:            backend-tbc-anf (Azure NetApp Files)"
echo "  StorageClass:       azure-netapp-files"
echo "============================================================"
echo "Next: apply the PostgreSQL manifests in k8s/k8s/dev-postgres-anf/"

cat >> .infra-state.env <<EOF
TRIDENT_CLIENT_ID="$TRIDENT_CLIENT_ID"
EOF
