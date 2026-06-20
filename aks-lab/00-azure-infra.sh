#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-azure-infra.sh
# Prerequisite Azure infrastructure: VNet, subnets, AKS (CNI, with a subnet
# dedicated to AGIC), Azure SQL with a Private Endpoint, Key Vault, ACR.
# Run this BEFORE applying any Kubernetes YAML. Idempotent-ish; re-run safe
# for most steps (az will error on some "already exists" — check as you go).
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Variables: EDIT THESE ----
RG="rg-aks-lab"
LOCATION="centralindia"   # confirmed working for this subscription; eastus/eastus2 hit RegionDoesNotAllowProvisioning for SQL
VNET_NAME="vnet-aks-lab"
VNET_CIDR="10.10.0.0/16"
AKS_SUBNET_NAME="snet-aks"
AKS_SUBNET_CIDR="10.10.1.0/24"
AGIC_SUBNET_NAME="snet-appgw"
AGIC_SUBNET_CIDR="10.10.2.0/24"
SQL_SUBNET_NAME="snet-sql-pe"
SQL_SUBNET_CIDR="10.10.3.0/24"

AKS_NAME="aks-lab-cluster"
ACR_NAME="acrakslab$RANDOM"          # must be globally unique, lowercase/numbers only
KV_NAME="kv-aks-lab-$RANDOM"         # must be globally unique
SQL_SERVER_NAME="sqlsrv-aks-lab-$RANDOM"  # must be globally unique
SQL_DB_NAME="appdb"
SQL_ADMIN_USER="sqladminuser"
SQL_ADMIN_PASS="$(openssl rand -base64 24)"   # generated; you'll rotate via Key Vault anyway

APPGW_NAME="appgw-aks-lab"
APPGW_PUBLIC_IP_NAME="pip-appgw-aks-lab"

# ---------------------------------------------------------------------------
# wait_for_resource: polls `az resource show` on a resource ID until its
# provisioningState is "Succeeded", or until TIMEOUT_SECS elapses.
#
# Why this exists: az's create commands for some resource types (notably
# SQL servers) return control as soon as the control-plane operation is
# accepted, slightly before the resource is reliably queryable by every
# subsequent API call (e.g. `az sql server show`, or a private-endpoint
# create that needs to resolve --private-connection-resource-id). This
# caused a real failure during testing: a private-endpoint create command
# got "ResourceNotFound" on a SQL server that, seconds later, queried fine.
# This function closes that race by actively confirming the resource is
# visible and Succeeded before the script's next command depends on it.
#
# Usage: wait_for_resource "<full-resource-id>" "<friendly-name-for-logging>"
# ---------------------------------------------------------------------------
wait_for_resource() {
  local resource_id="$1"
  local label="${2:-resource}"
  local timeout_secs=300
  local interval_secs=5
  local elapsed=0

  echo "    ...waiting for $label to be queryable and Succeeded (timeout ${timeout_secs}s)"
  while [ "$elapsed" -lt "$timeout_secs" ]; do
    local state
    state=$(az resource show --ids "$resource_id" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "")
    if [ "$state" == "Succeeded" ]; then
      echo "    ...$label is ready (provisioningState=Succeeded) after ${elapsed}s"
      return 0
    fi
    sleep "$interval_secs"
    elapsed=$((elapsed + interval_secs))
  done

  echo "    ...WARNING: $label did not report Succeeded within ${timeout_secs}s (last state: '${state:-unknown}'). Continuing anyway — if the next step fails with ResourceNotFound, re-run this script; the resource is likely still propagating."
  return 0
}

echo "==> Resource Group"
az group create -n "$RG" -l "$LOCATION"

# ---------------------------------------------------------------------------
# Guard against resuming into a partially-completed previous run. This
# script is NOT safe to re-run blindly once resources like the SQL private
# endpoint exist, because the VNet/subnet create calls that follow will
# conflict with an in-use subnet (seen during testing: "InUseSubnetCannotBeDeleted").
# If a previous attempt got partway through, the safest move is a full
# `az group delete -n $RG --yes` (wait for it to finish, no --no-wait) before
# re-running this script. This check won't fix that for you — it just stops
# you from hitting a confusing downstream error instead of a clear one.
# ---------------------------------------------------------------------------
EXISTING_RESOURCES=$(az resource list -g "$RG" --query "length([])" -o tsv)
if [ "$EXISTING_RESOURCES" -gt 0 ]; then
  echo ""
  echo "WARNING: resource group '$RG' already contains $EXISTING_RESOURCES resource(s)"
  echo "from a previous run. This script is not safe to resume on top of"
  echo "partially-created infra (it can hit subnet/private-endpoint conflicts)."
  echo ""
  az resource list -g "$RG" -o table
  echo ""
  read -r -p "Continue anyway? Only do this if you're sure these resources are compatible with a fresh run (y/N): " CONTINUE_ANYWAY
  if [ "$CONTINUE_ANYWAY" != "y" ] && [ "$CONTINUE_ANYWAY" != "Y" ]; then
    echo "Aborting. Recommended: az group delete -n $RG --yes   (wait for it to fully finish), then re-run."
    exit 1
  fi
fi

echo "==> VNet + Subnets"
az network vnet create -g "$RG" -n "$VNET_NAME" --address-prefix "$VNET_CIDR" \
  --subnet-name "$AKS_SUBNET_NAME" --subnet-prefix "$AKS_SUBNET_CIDR"

VNET_ID=$(az network vnet show -g "$RG" -n "$VNET_NAME" --query id -o tsv)
wait_for_resource "$VNET_ID" "VNet $VNET_NAME"

az network vnet subnet create -g "$RG" --vnet-name "$VNET_NAME" \
  -n "$AGIC_SUBNET_NAME" --address-prefix "$AGIC_SUBNET_CIDR"

az network vnet subnet create -g "$RG" --vnet-name "$VNET_NAME" \
  -n "$SQL_SUBNET_NAME" --address-prefix "$SQL_SUBNET_CIDR" \
  --disable-private-endpoint-network-policies true

echo "==> ACR"
az acr create -g "$RG" -n "$ACR_NAME" --sku Standard

echo "==> AKS (CNI networking so AGIC + NetworkPolicy both work)"
AKS_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" \
  -n "$AKS_SUBNET_NAME" --query id -o tsv)

az aks create -g "$RG" -n "$AKS_NAME" \
  --network-plugin azure \
  --network-policy azure \
  --vnet-subnet-id "$AKS_SUBNET_ID" \
  --enable-managed-identity \
  --attach-acr "$ACR_NAME" \
  --enable-addons azure-keyvault-secrets-provider \
  --enable-secret-rotation \
  --node-count 2 \
  --generate-ssh-keys

az aks get-credentials -g "$RG" -n "$AKS_NAME" --overwrite-existing

echo "==> dev namespace"
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

echo "==> Key Vault"
az keyvault create -g "$RG" -n "$KV_NAME" -l "$LOCATION" --enable-rbac-authorization false

KV_ID=$(az keyvault show -g "$RG" -n "$KV_NAME" --query id -o tsv)
wait_for_resource "$KV_ID" "Key Vault $KV_NAME"

echo "==> Store initial SQL admin password in Key Vault"
az keyvault secret set --vault-name "$KV_NAME" --name "sql-admin-password" --value "$SQL_ADMIN_PASS"

echo "==> Azure SQL logical server (public network access disabled — private endpoint only)"
az sql server create -g "$RG" -n "$SQL_SERVER_NAME" \
  --admin-user "$SQL_ADMIN_USER" --admin-password "$SQL_ADMIN_PASS" \
  --enable-public-network false

SQL_SERVER_ID_EARLY=$(az sql server show -g "$RG" -n "$SQL_SERVER_NAME" --query id -o tsv)
wait_for_resource "$SQL_SERVER_ID_EARLY" "SQL server $SQL_SERVER_NAME"

az sql db create -g "$RG" -s "$SQL_SERVER_NAME" -n "$SQL_DB_NAME" \
  --service-objective S0

echo "==> Private Endpoint for SQL server in snet-sql-pe"
SQL_SERVER_ID=$(az sql server show -g "$RG" -n "$SQL_SERVER_NAME" --query id -o tsv)

az network private-endpoint create -g "$RG" -n "pe-$SQL_SERVER_NAME" \
  --vnet-name "$VNET_NAME" --subnet "$SQL_SUBNET_NAME" \
  --private-connection-resource-id "$SQL_SERVER_ID" \
  --group-id sqlServer --connection-name "sqlpe-conn"

PE_ID=$(az network private-endpoint show -g "$RG" -n "pe-$SQL_SERVER_NAME" --query id -o tsv)
wait_for_resource "$PE_ID" "private endpoint pe-$SQL_SERVER_NAME"

echo "==> Private DNS zone for privatelink.database.windows.net"
az network private-dns zone create -g "$RG" -n "privatelink.database.windows.net"

az network private-dns link vnet create -g "$RG" \
  -z "privatelink.database.windows.net" -n "sql-dns-link" \
  -v "$VNET_NAME" -e false

az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name "pe-$SQL_SERVER_NAME" --name "sql-dns-zone-group" \
  --private-dns-zone "privatelink.database.windows.net" \
  --zone-name "sql"

echo "==> Resolve the private IP assigned to the SQL private endpoint"
SQL_PRIVATE_IP=$(az network private-endpoint show -g "$RG" -n "pe-$SQL_SERVER_NAME" \
  --query "customDnsConfigs[0].ipAddresses[0]" -o tsv)
echo "SQL private IP: $SQL_PRIVATE_IP"
echo "FQDN (resolves to private IP from inside the VNet): ${SQL_SERVER_NAME}.database.windows.net"

echo "==> Grant AKS Key Vault Secrets Provider managed identity access to Key Vault"
KUBELET_IDENTITY_OBJECT_ID=$(az aks show -g "$RG" -n "$AKS_NAME" \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)

# This identity's object ID can occasionally lag slightly behind AAD's own
# replication right after AKS finishes provisioning the addon, even though
# the cluster itself reports Succeeded. If keyvault set-policy below fails
# with an "ObjectId not found in AAD" type error, that's this same race —
# re-run the script.
az keyvault set-policy -n "$KV_NAME" \
  --object-id "$KUBELET_IDENTITY_OBJECT_ID" \
  --secret-permissions get list

echo "==> (For AGIC) Create Application Gateway public IP + App Gateway, then enable AGIC add-on"
az network public-ip create -g "$RG" -n "$APPGW_PUBLIC_IP_NAME" --allocation-method Static --sku Standard

AGIC_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" \
  -n "$AGIC_SUBNET_NAME" --query id -o tsv)

az network application-gateway create -g "$RG" -n "$APPGW_NAME" \
  --sku Standard_v2 --public-ip-address "$APPGW_PUBLIC_IP_NAME" \
  --subnet "$AGIC_SUBNET_ID" --priority 100

APPGW_ID=$(az network application-gateway show -g "$RG" -n "$APPGW_NAME" --query id -o tsv)
wait_for_resource "$APPGW_ID" "Application Gateway $APPGW_NAME"

az aks enable-addons -g "$RG" -n "$AKS_NAME" \
  --addons ingress-appgw --appgw-id "$APPGW_ID"

echo "============================================================"
echo "DONE. Capture these values — you'll need them in the YAML:"
echo "  Resource Group:        $RG"
echo "  AKS cluster:           $AKS_NAME"
echo "  ACR:                   $ACR_NAME"
echo "  Key Vault name:        $KV_NAME"
echo "  Key Vault tenant ID:   $(az account show --query tenantId -o tsv)"
echo "  SQL server:            ${SQL_SERVER_NAME}.database.windows.net"
echo "  SQL DB:                $SQL_DB_NAME"
echo "  SQL admin user:        $SQL_ADMIN_USER"
echo "  SQL private IP:        $SQL_PRIVATE_IP"
echo "  App Gateway:           $APPGW_NAME"
echo "============================================================"

# ---------------------------------------------------------------------------
# Write all values needed downstream to a state file. run-all.sh sources this
# instead of scraping the echo output above, so it's the authoritative
# machine-readable record of this run. Re-running this script overwrites it.
# ---------------------------------------------------------------------------
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.infra-state.env"
cat > "$STATE_FILE" <<EOF
RG="$RG"
LOCATION="$LOCATION"
VNET_NAME="$VNET_NAME"
SQL_SUBNET_CIDR="$SQL_SUBNET_CIDR"
AKS_NAME="$AKS_NAME"
ACR_NAME="$ACR_NAME"
KV_NAME="$KV_NAME"
TENANT_ID="$(az account show --query tenantId -o tsv)"
SQL_SERVER_NAME="$SQL_SERVER_NAME"
SQL_DB_NAME="$SQL_DB_NAME"
SQL_ADMIN_USER="$SQL_ADMIN_USER"
SQL_PRIVATE_IP="$SQL_PRIVATE_IP"
APPGW_NAME="$APPGW_NAME"
EOF
echo "State written to: $STATE_FILE"
