#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rotate-sql-password.sh
# Updates the RDS SQL Server admin password AND the corresponding secret
# in AWS Secrets Manager, in one flow. Run this whenever you need to
# rotate the DB password.
#
# Same caveat as the AKS lab: pods consuming SQL_PASSWORD as an env var
# (as in 04-deployment-service.yaml) will NOT pick up the new password
# until they restart, since env vars are only read at container start.
# The Secrets Store CSI driver (with enableSecretRotation=true, set in
# 01-aws-lbc-and-identity.sh) will refresh the MOUNTED FILE in running
# pods automatically — but the synced Kubernetes Secret env vars still
# need a pod restart. This script does that restart for you.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./.infra-state.env

NAMESPACE="dev"
DEPLOYMENT_NAME="dotnet-helloworld"

NEW_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-30)"

echo "==> Updating RDS SQL Server admin password"
aws rds modify-db-instance \
  --db-instance-identifier "$SQL_SERVER_NAME" \
  --master-user-password "$NEW_PASSWORD" \
  --apply-immediately \
  --region "$REGION"

echo "    ...waiting for RDS to apply the change"
aws rds wait db-instance-available --db-instance-identifier "$SQL_SERVER_NAME" --region "$REGION"

echo "==> Updating Secrets Manager (preserving the other fields in the JSON secret)"
CURRENT_SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text)
UPDATED_SECRET=$(echo "$CURRENT_SECRET" | jq --arg pw "$NEW_PASSWORD" '.password = $pw')

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_NAME" \
  --secret-string "$UPDATED_SECRET" \
  --region "$REGION"

echo "==> Restarting deployment so env-var-based pods pick up the new password"
kubectl rollout restart deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"
kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"

echo "Password rotated and propagated."
