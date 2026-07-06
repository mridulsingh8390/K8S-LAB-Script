#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00b-gcp-filestore.sh
# Creates a Google Cloud Filestore instance for in-cluster PostgreSQL
# storage — GCP's NFS-based equivalent of Azure ANF / AWS EFS.
#
# Filestore is structurally simpler than Azure ANF (no delegated subnet,
# no third-party operator needed) but more expensive for small POC usage
# since the minimum instance size is 1 TiB on the BASIC_HDD tier.
# The Filestore CSI driver is BUILT INTO GKE (enabled by default on
# clusters created with --addons=GcpFilestoreCsiDriver, or manually
# below) — no separate Helm install like EFS or Trident needed.
#
# Run AFTER 00-gcp-infra.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ./.infra-state.env ]; then
  echo "ERROR: .infra-state.env not found. Run 00-gcp-infra.sh first."
  exit 1
fi
source ./.infra-state.env

FILESTORE_NAME="gke-lab-postgres-fs"
FILESTORE_TIER="BASIC_HDD"        # minimum cost; BASIC_SSD for better I/O
FILESTORE_CAPACITY_GB="1024"      # 1 TiB — minimum on BASIC_HDD
FILESTORE_SHARE_NAME="pgdata"
FILESTORE_ZONE="${ZONE}"

echo "==> Enabling Filestore CSI driver addon on the GKE cluster"
gcloud container clusters update "$CLUSTER_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --update-addons=GcpFilestoreCsiDriver=ENABLED

echo "==> Creating Filestore instance (this takes 3-5 minutes)"
gcloud filestore instances create "$FILESTORE_NAME" \
  --project "$PROJECT_ID" \
  --zone "$FILESTORE_ZONE" \
  --tier="$FILESTORE_TIER" \
  --file-share=name="${FILESTORE_SHARE_NAME}",capacity="${FILESTORE_CAPACITY_GB}GB" \
  --network=name="${VPC_NAME}" 2>/dev/null || echo "   (instance already exists, continuing)"

echo "    ...waiting for Filestore to become READY"
while true; do
  STATE=$(gcloud filestore instances describe "$FILESTORE_NAME" \
    --project "$PROJECT_ID" --zone "$FILESTORE_ZONE" \
    --format="value(state)" 2>/dev/null)
  [ "$STATE" = "READY" ] && break
  echo "    ...state: $STATE, waiting..."
  sleep 15
done

FILESTORE_IP=$(gcloud filestore instances describe "$FILESTORE_NAME" \
  --project "$PROJECT_ID" --zone "$FILESTORE_ZONE" \
  --format="value(networks[0].ipAddresses[0])")

echo "============================================================"
echo "DONE."
echo "  Filestore instance: $FILESTORE_NAME"
echo "  NFS IP address:     $FILESTORE_IP"
echo "  Share name:         $FILESTORE_SHARE_NAME"
echo "============================================================"
echo "Next: apply k8s/dev-postgres-filestore/ manifests"

cat >> .infra-state.env <<EOF
FILESTORE_NAME="$FILESTORE_NAME"
FILESTORE_IP="$FILESTORE_IP"
FILESTORE_SHARE_NAME="$FILESTORE_SHARE_NAME"
FILESTORE_ZONE="$FILESTORE_ZONE"
EOF
echo "Appended Filestore state to .infra-state.env"
