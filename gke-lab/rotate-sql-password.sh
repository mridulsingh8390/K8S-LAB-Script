#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rotate-sql-password.sh
# Updates the Cloud SQL admin password AND the corresponding Secret Manager
# secret, in one flow. Run this whenever you need to rotate the DB password.
#
# Same caveat as the AKS/EKS labs: pods consuming SQL_PASSWORD as an env var
# (as in 04-deployment-service.yaml) will NOT pick up the new password
# until they restart, since env vars are only read at container start. The
# Secrets Store CSI driver (with enableSecretRotation=true, set in
# 01-gke-identity-and-sql.sh) will refresh the MOUNTED FILE in running pods
# automatically - but the synced Kubernetes Secret env vars still need a
# pod restart. This script does that restart for you.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./.infra-state.env

NAMESPACE="dev"
DEPLOYMENT_NAME="dotnet-helloworld"

NEW_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-30)"

echo "==> Updating Cloud SQL admin password"
gcloud sql users set-password "$SQL_ADMIN_USER" \
  --instance="$SQL_INSTANCE_NAME" \
  --project "$PROJECT_ID" \
  --password="$NEW_PASSWORD"

echo "==> Updating Secret Manager (gke-lab-sql-password)"
echo -n "$NEW_PASSWORD" | gcloud secrets versions add gke-lab-sql-password --project "$PROJECT_ID" --data-file=-

echo "==> Restarting deployment so env-var-based pods pick up the new password"
kubectl rollout restart deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"
kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"

echo "Password rotated and propagated."
