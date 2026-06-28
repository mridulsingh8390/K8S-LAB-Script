#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00b-azure-netapp-files.sh
# Prerequisite Azure infrastructure for running PostgreSQL IN-CLUSTER on AKS,
# with Azure NetApp Files (ANF) as the persistent storage backend, instead
# of using Azure SQL as a managed service.
#
# This is an ALTERNATE PATH alongside the original aks-lab — it does not
# replace 00-azure-infra.sh, it runs alongside/after it. The VNet, AKS
# cluster, Key Vault, ACR, NetworkPolicy, and AGIC from the original lab are
# all reused unchanged; only the database layer is different.
#
# What changes vs. the managed Azure SQL approach:
#   Azure SQL (managed service)        -> PostgreSQL running as a pod (StatefulSet) in AKS
#   Private Endpoint                   -> Azure NetApp Files volume, NFS-mounted into the pod
#   (no separate provisioner needed)   -> Astra Trident CSI driver (NetApp's own provisioner,
#                                          required for dynamic ANF volume provisioning)
#
# WHY THIS IS A BIGGER LIFT THAN IT SOUNDS: Azure NetApp Files is not just
# "a different StorageClass" - it requires its own delegated subnet in the
# VNet, an ANF account and capacity pool (billed by capacity pool size, not
# by what you actually use), and a separate CSI driver (Trident) installed
# via Helm, with its own backend configuration holding Azure credentials.
# None of this exists for standard Azure Disk-backed storage, which would
# have been a much simpler choice if you didn't specifically need ANF's
# NFS/shared-access/enterprise features.
#
# Run this AFTER 00-azure-infra.sh has already created the VNet and AKS
# cluster (this script reads VNET_NAME, RG, LOCATION from .infra-state.env).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ./.infra-state.env ]; then
  echo "ERROR: .infra-state.env not found. Run 00-azure-infra.sh first - this script reuses its VNet and resource group."
  exit 1
fi
source ./.infra-state.env

# ---- Variables: EDIT THESE ----
ANF_ACCOUNT_NAME="anfaccount${RANDOM}"
ANF_POOL_NAME="anfpool1"
ANF_POOL_SIZE_TIB=4          # 4 TiB is the minimum capacity pool size on the Standard tier
ANF_SERVICE_LEVEL="Standard"  # Standard | Premium | Ultra - affects throughput per TiB, and cost
ANF_SUBNET_NAME="snet-anf"
ANF_SUBNET_CIDR="10.10.4.0/24"   # must not overlap snet-aks/snet-appgw/snet-sql-pe from 00-azure-infra.sh
ANF_VOLUME_NAME="pgdata"
ANF_VOLUME_SIZE_GIB=100

wait_for_resource() {
  local check_cmd="$1"
  local label="${2:-resource}"
  local timeout_secs="${3:-300}"
  local interval_secs=10
  local elapsed=0
  echo "    ...waiting for $label (timeout ${timeout_secs}s)"
  while [ "$elapsed" -lt "$timeout_secs" ]; do
    if eval "$check_cmd" >/dev/null 2>&1; then
      echo "    ...$label is ready after ${elapsed}s"
      return 0
    fi
    sleep "$interval_secs"
    elapsed=$((elapsed + interval_secs))
  done
  echo "    ...WARNING: $label did not become ready within ${timeout_secs}s. Continuing anyway."
  return 0
}

echo "==> Registering the Microsoft.NetApp resource provider (one-time per subscription, no-op if already done)"
az provider register --namespace Microsoft.NetApp
wait_for_resource "az provider show -n Microsoft.NetApp --query registrationState -o tsv | grep -q Registered" \
  "Microsoft.NetApp provider registration" 300

echo "==> Delegated subnet for Azure NetApp Files (required - ANF volumes must live in a delegated subnet)"
az network vnet subnet create -g "$RG" --vnet-name "$VNET_NAME" \
  -n "$ANF_SUBNET_NAME" --address-prefix "$ANF_SUBNET_CIDR" \
  --delegations "Microsoft.NetApp/volumes"

echo "==> Azure NetApp Files account"
az netappfiles account create -g "$RG" -a "$ANF_ACCOUNT_NAME" -l "$LOCATION"

echo "==> Capacity pool (billed by pool size regardless of how much you actually use - 4 TiB is the practical minimum)"
az netappfiles pool create -g "$RG" -a "$ANF_ACCOUNT_NAME" -p "$ANF_POOL_NAME" \
  -l "$LOCATION" --size "$ANF_POOL_SIZE_TIB" --service-level "$ANF_SERVICE_LEVEL"

ANF_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n "$ANF_SUBNET_NAME" --query id -o tsv)

echo "    ...this lab uses Trident for DYNAMIC provisioning (see 01b-install-trident.sh), so we do NOT"
echo "    pre-create an individual ANF volume here - Trident creates volumes on-demand from PVCs."
echo "    The account + pool above are the prerequisites Trident needs to provision into."

echo "============================================================"
echo "DONE. Capture these values:"
echo "  ANF account:       $ANF_ACCOUNT_NAME"
echo "  ANF pool:          $ANF_POOL_NAME"
echo "  ANF subnet ID:     $ANF_SUBNET_ID"
echo "  Service level:     $ANF_SERVICE_LEVEL"
echo "============================================================"
echo "Next: run ./01b-install-trident.sh"

cat >> .infra-state.env <<EOF
ANF_ACCOUNT_NAME="$ANF_ACCOUNT_NAME"
ANF_POOL_NAME="$ANF_POOL_NAME"
ANF_SUBNET_ID="$ANF_SUBNET_ID"
ANF_SERVICE_LEVEL="$ANF_SERVICE_LEVEL"
ANF_VOLUME_NAME="$ANF_VOLUME_NAME"
ANF_VOLUME_SIZE_GIB="$ANF_VOLUME_SIZE_GIB"
EOF
echo "Appended ANF state to .infra-state.env"
