#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh
# Tears down everything created by the gke-lab scripts. Like the EKS lab
# (and unlike the AKS lab's single `az group delete`), GCP has no single
# command that deletes everything tagged as "this lab" at once - each
# resource type needs its own delete call, in dependency order.
#
# Order matters here specifically because of Private Service Access: the
# VPC peering connection to Google's service-producer network cannot be
# removed while a Cloud SQL instance is still using an IP from that range,
# and the VPC itself cannot be deleted while the GKE cluster (which uses
# it) or the peering connection still exist.
#
# WARNING: This is destructive and irreversible. Confirmation prompt
# unless --yes is passed.
#
# Usage:
#   ./cleanup.sh           # interactive
#   ./cleanup.sh --yes     # skip confirmation
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AUTO_YES="false"
if [ "${1:-}" == "--yes" ]; then
  AUTO_YES="true"
fi

if [ -f ./.infra-state.env ]; then
  source ./.infra-state.env
  echo "==> Loaded state from .infra-state.env"
else
  echo "==> No .infra-state.env found - you'll need to supply these manually below if they're empty."
  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
  REGION="${REGION:-us-central1}"
  ZONE="${ZONE:-us-central1-a}"
  CLUSTER_NAME="${CLUSTER_NAME:-gke-lab-cluster}"
  VPC_NAME="${VPC_NAME:-gke-lab-vpc}"
fi

echo "############################################################"
echo "# This will permanently delete:"
echo "#   GKE cluster:        ${CLUSTER_NAME:-<unknown>}"
echo "#   Cloud SQL instance: ${SQL_INSTANCE_NAME:-<unknown>}"
echo "#   Secret Manager:     5 SQL credential secrets"
echo "#   Artifact Registry:  ${AR_REPO_NAME:-<unknown>}"
echo "#   GSA/IAM bindings created for this lab"
echo "#   VPC, subnet, firewall rule, PSA peering: ${VPC_NAME:-<unknown>}"
echo "############################################################"

if [ "$AUTO_YES" != "true" ]; then
  read -r -p "Type the project ID to confirm deletion ($PROJECT_ID): " CONFIRM
  if [ "$CONFIRM" != "$PROJECT_ID" ]; then
    echo "Confirmation did not match. Aborting - nothing was deleted."
    exit 1
  fi
fi

echo "==> Removing local kubectl context (best-effort)"
kubectl config delete-context "$(kubectl config current-context 2>/dev/null)" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Delete the Ingress first, so GKE's controller has a chance to clean up
#    the load balancer, NEGs, and health checks it created - skipping this
#    can orphan those Compute Engine resources, which then need manual
#    cleanup from the console (same risk as the EKS lab's ALB).
# ---------------------------------------------------------------------------
echo "==> Deleting Ingress (lets GKE deprovision the load balancer cleanly)"
kubectl delete ingress dotnet-helloworld-ingress -n dev 2>/dev/null || true
echo "    waiting 60s for load balancer deprovisioning..."
sleep 60

# ---------------------------------------------------------------------------
# 2. Delete Cloud SQL instance (must happen before removing the PSA peering,
#    since the instance holds an IP from that peered range)
# ---------------------------------------------------------------------------
if [ -n "${SQL_INSTANCE_NAME:-}" ]; then
  echo "==> Deleting Cloud SQL instance: $SQL_INSTANCE_NAME"
  gcloud sql instances delete "$SQL_INSTANCE_NAME" --project "$PROJECT_ID" --quiet 2>/dev/null || \
    echo "   (instance not found or already deleting)"
fi

# ---------------------------------------------------------------------------
# 3. Delete Secret Manager secrets
# ---------------------------------------------------------------------------
echo "==> Deleting Secret Manager secrets"
for secret_id in gke-lab-sql-username gke-lab-sql-password gke-lab-sql-host gke-lab-sql-port gke-lab-sql-dbname; do
  gcloud secrets delete "$secret_id" --project "$PROJECT_ID" --quiet 2>/dev/null || \
    echo "   ($secret_id not found, continuing)"
done

# ---------------------------------------------------------------------------
# 4. Delete Artifact Registry repository
# ---------------------------------------------------------------------------
if [ -n "${AR_REPO_NAME:-}" ]; then
  echo "==> Deleting Artifact Registry repository: $AR_REPO_NAME"
  gcloud artifacts repositories delete "$AR_REPO_NAME" --project "$PROJECT_ID" --location="${REGION:-us-central1}" --quiet 2>/dev/null || \
    echo "   (repository not found, continuing)"
fi

# ---------------------------------------------------------------------------
# 5. Delete the GSA and its IAM bindings (global, not region-scoped)
# ---------------------------------------------------------------------------
echo "==> Deleting workload identity GSA"
gcloud iam service-accounts delete "${GSA_EMAIL:-gke-lab-dotnet-app-gsa@${PROJECT_ID}.iam.gserviceaccount.com}" \
  --project "$PROJECT_ID" --quiet 2>/dev/null || echo "   (GSA not found, continuing)"

# ---------------------------------------------------------------------------
# 6. Delete the GKE cluster
# ---------------------------------------------------------------------------
echo "==> Deleting GKE cluster: $CLUSTER_NAME (this takes 5-10+ minutes)"
gcloud container clusters delete "$CLUSTER_NAME" --project "$PROJECT_ID" --zone "${ZONE:-us-central1-a}" --quiet 2>/dev/null || \
  echo "   (cluster not found or already deleting)"

# ---------------------------------------------------------------------------
# 7. Remove the Private Service Access peering connection (must come after
#    the Cloud SQL instance is gone)
# ---------------------------------------------------------------------------
echo "==> Removing the Private Service Access peering connection"
gcloud services vpc-peerings delete \
  --project "$PROJECT_ID" \
  --service=servicenetworking.googleapis.com \
  --network="${VPC_NAME:-gke-lab-vpc}" --quiet 2>/dev/null || \
  echo "   (peering connection not found, already deleted, or could not be removed - check manually if needed)"

echo "==> Releasing the PSA IP range"
gcloud compute addresses delete gke-lab-psa-range --project "$PROJECT_ID" --global --quiet 2>/dev/null || \
  echo "   (PSA range not found, continuing)"

# ---------------------------------------------------------------------------
# 8. Delete the firewall rule, subnet, and VPC
# ---------------------------------------------------------------------------
echo "==> Deleting firewall rule"
gcloud compute firewall-rules delete "${VPC_NAME:-gke-lab-vpc}-allow-internal" --project "$PROJECT_ID" --quiet 2>/dev/null || \
  echo "   (firewall rule not found, continuing)"

echo "==> Deleting subnet"
gcloud compute networks subnets delete "${SUBNET_NAME:-gke-lab-subnet}" --project "$PROJECT_ID" --region="${REGION:-us-central1}" --quiet 2>/dev/null || \
  echo "   (subnet not found, continuing)"

echo "==> Deleting VPC"
gcloud compute networks delete "${VPC_NAME:-gke-lab-vpc}" --project "$PROJECT_ID" --quiet 2>/dev/null || \
  echo "   (VPC not found, still has dependencies, or could not be removed - check manually if so)"

if [ -f ./.infra-state.env ]; then
  rm -f ./.infra-state.env
  echo "==> Removed local .infra-state.env"
fi

echo ""
echo "Done. Double-check the GCP Console (Compute Engine -> Load balancing,"
echo "VPC network -> Firewall, IAM & Admin -> Service Accounts) for any"
echo "resources this script couldn't find by name - particularly orphaned"
echo "load balancers/NEGs/health checks, which are the most common leftovers"
echo "if the Ingress deletion step above didn't get a chance to fully"
echo "deprovision before the cluster was deleted."
