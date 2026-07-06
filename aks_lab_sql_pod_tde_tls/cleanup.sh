#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh
# Tears down everything created by 00-azure-infra.sh / run-all.sh in one
# shot. Since every resource (AKS, VNet, ACR, Key Vault, SQL server +
# private endpoint, App Gateway, public IP, private DNS zone) lives inside
# a single resource group, deleting that resource group is sufficient and
# is the approach this script uses — far more reliable than deleting each
# resource individually, and it cleans up correctly even if a previous run
# only partially completed.
#
# It also removes the locally-generated kubectl context for the cluster and
# the local user-assigned identity (id-dotnet-app), since that identity is
# NOT inside the resource group's deletion scope by default if you created
# it with a different -g than $RG (it isn't, in this lab — it's created in
# the same RG by run-all.sh — but the explicit deletion is kept as a
# defensive no-op in case you ever change that).
#
# WARNING: This is destructive and irreversible. It deletes real Azure
# resources, including the SQL database and any data in it. There is a
# confirmation prompt before anything happens; pass --yes to skip it
# (useful for CI or repeated lab teardown/rebuild cycles).
#
# Usage:
#   ./cleanup.sh           # interactive, asks for confirmation
#   ./cleanup.sh --yes     # skips the confirmation prompt
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AUTO_YES="false"
if [ "${1:-}" == "--yes" ]; then
  AUTO_YES="true"
fi

# ---------------------------------------------------------------------------
# Resolve the resource group + AKS cluster name. Prefer the state file
# written by 00-azure-infra.sh (authoritative, has the real generated names);
# fall back to the known defaults from that script if the state file is
# missing (e.g. you're cleaning up after editing the script's variables, or
# the state file was deleted).
# ---------------------------------------------------------------------------
if [ -f ./.infra-state.env ]; then
  source ./.infra-state.env
  echo "==> Loaded state from .infra-state.env"
else
  echo "==> No .infra-state.env found, falling back to script defaults"
  RG="rg-aks-lab"
  AKS_NAME="aks-lab-cluster"
fi

echo "############################################################"
echo "# This will permanently delete:"
echo "#   Resource Group: $RG"
echo "#   (and everything inside it: AKS, VNet, ACR, Key Vault,"
echo "#    SQL server + database, private endpoint, App Gateway,"
echo "#    public IP, private DNS zone, managed identity, etc.)"
echo "############################################################"

if [ "$AUTO_YES" != "true" ]; then
  read -r -p "Type the resource group name to confirm deletion ($RG): " CONFIRM
  if [ "$CONFIRM" != "$RG" ]; then
    echo "Confirmation did not match. Aborting — nothing was deleted."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Best-effort: remove local kubectl context first so you don't have a
# dangling/broken context pointing at a cluster that's about to disappear.
# Not fatal if this fails (e.g. context never existed).
# ---------------------------------------------------------------------------
echo "==> Removing local kubectl context for $AKS_NAME (best-effort)"
kubectl config delete-context "$AKS_NAME" 2>/dev/null || true
kubectl config delete-cluster "$AKS_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
# The actual deletion. --no-wait returns immediately; the deletion continues
# in the background on Azure's side. Remove --no-wait if you want this
# script to block until everything is fully gone (can take 15-20+ minutes
# for AKS + SQL + App Gateway).
# ---------------------------------------------------------------------------
if az group exists -n "$RG" | grep -qi true; then
  echo "==> Deleting resource group: $RG (running in background, --no-wait)"
  az group delete -n "$RG" --yes --no-wait
  echo ""
  echo "Deletion submitted. Azure is tearing down all resources in the"
  echo "background — this typically takes 15-20+ minutes for everything"
  echo "to fully disappear (App Gateway and SQL private endpoints are"
  echo "usually the slowest)."
  echo ""
  echo "Check status any time with:"
  echo "  az group exists -n $RG"
  echo "  az group show -n $RG --query properties.provisioningState -o tsv"
  echo ""
  echo "Once 'az group exists -n $RG' returns false, it's fully gone."
else
  echo "Resource group '$RG' does not exist — nothing to delete."
fi

# ---------------------------------------------------------------------------
# Clean up the local state file so a future run starts fresh.
# ---------------------------------------------------------------------------
if [ -f ./.infra-state.env ]; then
  rm -f ./.infra-state.env
  echo "==> Removed local .infra-state.env"
fi

echo "Done. Re-run run-all.sh whenever you want to rebuild the lab from scratch."
