#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-all.sh
# End-to-end orchestrator. Run this ONE script from the aks-lab/ directory
# and it will:
#   1. Run 00-azure-infra.sh (Azure infra: VNet, AKS, ACR, KV, SQL+PE, AppGW)
#   2. Create + federate a user-assigned managed identity for workload
#      identity (so the Key Vault CSI driver can authenticate)
#   3. Substitute every <PLACEHOLDER> in the k8s YAML and helper scripts
#      with real values from step 1 and 2 — no manual editing needed
#   4. Build and push the dotnet image to ACR
#   5. kubectl apply everything in the correct order
#   6. Print a summary + the verification commands to run
#
# Run it as:  ./run-all.sh
#
# Re-running: steps 1 and 2 are not fully idempotent (some `az` create
# commands error if the resource already exists). If you need to re-run
# after a partial failure, comment out the steps that already succeeded,
# or `az group delete -n rg-aks-lab` first for a clean slate.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="dev"
IDENTITY_NAME="id-dotnet-app"
SA_NAME="dotnet-app-sa"
IMAGE_NAME="dotnet-helloworld"
IMAGE_TAG="v1"
REPO_URL="https://github.com/mridulsingh8390/dotnet8.git"

# ---------------------------------------------------------------------------
# Step 1: Azure infrastructure
# ---------------------------------------------------------------------------
echo "############################################################"
echo "# STEP 1/5: Azure infrastructure (this takes ~20-30 min)"
echo "############################################################"
chmod +x ./00-azure-infra.sh
./00-azure-infra.sh

# Load the values that script just wrote out
source ./.infra-state.env

echo "Loaded state for RG=$RG, AKS=$AKS_NAME, ACR=$ACR_NAME, KV=$KV_NAME"

# ---------------------------------------------------------------------------
# Step 2: Workload identity + federation for the Key Vault CSI driver
# ---------------------------------------------------------------------------
echo "############################################################"
echo "# STEP 2/5: Workload identity federation"
echo "############################################################"

# Make sure the OIDC issuer is enabled on the cluster (required for
# federated credentials). The infra script's `az aks create` does not set
# this flag explicitly, so enable it here if it isn't already on.
OIDC_ENABLED=$(az aks show -g "$RG" -n "$AKS_NAME" --query "oidcIssuerProfile.enabled" -o tsv)
if [ "$OIDC_ENABLED" != "true" ]; then
  echo "==> Enabling OIDC issuer + workload identity on the cluster"
  az aks update -g "$RG" -n "$AKS_NAME" --enable-oidc-issuer --enable-workload-identity
fi

OIDC_ISSUER_URL=$(az aks show -g "$RG" -n "$AKS_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)

echo "==> Creating user-assigned managed identity: $IDENTITY_NAME"
az identity create -g "$RG" -n "$IDENTITY_NAME" -l "$LOCATION" >/dev/null

IDENTITY_CLIENT_ID=$(az identity show -g "$RG" -n "$IDENTITY_NAME" --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show -g "$RG" -n "$IDENTITY_NAME" --query principalId -o tsv)

echo "==> Federating identity with ServiceAccount system:serviceaccount:${NAMESPACE}:${SA_NAME}"
az identity federated-credential create \
  -g "$RG" --identity-name "$IDENTITY_NAME" \
  --name "dotnet-app-fed" \
  --issuer "$OIDC_ISSUER_URL" \
  --subject "system:serviceaccount:${NAMESPACE}:${SA_NAME}" \
  --audiences "api://AzureADTokenExchange" 2>/dev/null || \
  echo "   (federated credential already exists, continuing)"

echo "==> Granting the identity get/list on Key Vault secrets"
az keyvault set-policy -n "$KV_NAME" \
  --object-id "$IDENTITY_PRINCIPAL_ID" \
  --secret-permissions get list >/dev/null

# Also store the username secret in Key Vault, since 02-secretproviderclass.yaml
# expects a "sql-admin-username" secret object (the infra script only stored
# sql-admin-password).
echo "==> Storing sql-admin-username in Key Vault (needed by SecretProviderClass)"
az keyvault secret set --vault-name "$KV_NAME" --name "sql-admin-username" --value "$SQL_ADMIN_USER" >/dev/null

# ---------------------------------------------------------------------------
# Step 3: Substitute placeholders across YAML + scripts
# ---------------------------------------------------------------------------
echo "############################################################"
echo "# STEP 3/5: Filling in placeholders"
echo "############################################################"

substitute() {
  local file="$1"
  sed -i \
    -e "s|<USER-ASSIGNED-IDENTITY-CLIENT-ID>|${IDENTITY_CLIENT_ID}|g" \
    -e "s|<KEY-VAULT-NAME>|${KV_NAME}|g" \
    -e "s|<AZURE-TENANT-ID>|${TENANT_ID}|g" \
    -e "s|<SQL_SERVER_NAME>|${SQL_SERVER_NAME}|g" \
    -e "s|<SQL-PRIVATE-ENDPOINT-IP>|${SQL_PRIVATE_IP}|g" \
    -e "s|<ACR_NAME>|${ACR_NAME}|g" \
    "$file"
  echo "   updated: $file"
}

for f in \
  k8s/dev/01-serviceaccount.yaml \
  k8s/dev/02-secretproviderclass.yaml \
  k8s/dev/03-configmap.yaml \
  k8s/dev/04-deployment-service.yaml \
  rotate-sql-password.sh \
  build-and-push.sh
do
  substitute "$f"
done

# ---------------------------------------------------------------------------
# Step 4: Build and push the image
# ---------------------------------------------------------------------------
echo "############################################################"
echo "# STEP 4/5: Build and push dotnet image to ACR"
echo "############################################################"

WORKDIR="$(mktemp -d)"
echo "==> Cloning $REPO_URL"
git clone --depth 1 "$REPO_URL" "$WORKDIR/src"

cp app/Dockerfile "$WORKDIR/src/Dockerfile"
cp app/.dockerignore "$WORKDIR/src/.dockerignore"

echo "==> NOTE: verify the csproj/assembly name matches the Dockerfile ENTRYPOINT"
find "$WORKDIR/src" -name "*.csproj" -exec echo "   found csproj: {}" \;

echo "==> Building image"
docker build -t "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}" "$WORKDIR/src"

echo "==> Logging into ACR and pushing"
az acr login --name "$ACR_NAME"
docker push "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"

rm -rf "$WORKDIR"

# ---------------------------------------------------------------------------
# Step 5: Apply Kubernetes manifests
# ---------------------------------------------------------------------------
echo "############################################################"
echo "# STEP 5/5: Applying Kubernetes manifests"
echo "############################################################"

az aks get-credentials -g "$RG" -n "$AKS_NAME" --overwrite-existing

kubectl apply -f k8s/dev/00-namespace.yaml
kubectl apply -f k8s/dev/01-serviceaccount.yaml
kubectl apply -f k8s/dev/02-secretproviderclass.yaml
kubectl apply -f k8s/dev/03-configmap.yaml
kubectl apply -f k8s/dev/04-deployment-service.yaml
kubectl apply -f k8s/dev/05-networkpolicy.yaml
kubectl apply -f k8s/dev/07-ingress-agic.yaml

echo "==> Waiting for deployment rollout"
kubectl rollout status deployment/dotnet-helloworld -n "$NAMESPACE" --timeout=180s || \
  echo "   (rollout didn't complete in time — check 'kubectl get pods -n dev' and 'kubectl describe pod' for details)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "############################################################"
echo "# DONE"
echo "############################################################"
echo "Resource Group:     $RG"
echo "AKS cluster:        $AKS_NAME"
echo "ACR image:           ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
echo "Key Vault:           $KV_NAME"
echo "SQL server FQDN:     ${SQL_SERVER_NAME}.database.windows.net"
echo "SQL private IP:      $SQL_PRIVATE_IP"
echo "Workload identity:   $IDENTITY_NAME (clientId: $IDENTITY_CLIENT_ID)"
echo ""
echo "Verify pods:          kubectl get pods -n dev"
echo "Verify env/secrets:   kubectl exec -n dev deploy/dotnet-helloworld -- env | grep SQL_"
echo "Verify ping policy:   kubectl apply -f k8s/dev/06-network-test-pods.yaml"
echo "                      then see README.md section 7 for the ping test commands"
echo "Rotate password:      ./rotate-sql-password.sh"
echo "Tear everything down: ./cleanup.sh"
echo "############################################################"
