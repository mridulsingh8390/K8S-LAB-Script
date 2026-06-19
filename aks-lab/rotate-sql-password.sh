#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rotate-sql-password.sh
# Updates the Azure SQL server admin password AND the corresponding secret
# in Key Vault, in one atomic-ish flow. Run this whenever you need to
# rotate the DB password.
#
# After this runs, the Key Vault CSI driver (with --enable-secret-rotation
# set on the AKS addon, as in the infra script) will automatically refresh
# the mounted secret file in running pods within its poll interval
# (default 2 minutes). The synced Kubernetes Secret (sql-credentials) is
# also updated, but pods using it as an ENV VAR (as in 04-deployment-
# service.yaml) will NOT pick up the change until they restart, since env
# vars are only read at container start. Roll the deployment after rotating
# if your app reads the password from env vars rather than re-reading the
# mounted file at runtime.
# ---------------------------------------------------------------------------
set -euo pipefail

RG="rg-aks-lab"
SQL_SERVER_NAME="<SQL_SERVER_NAME>"     # e.g. sqlsrv-aks-lab-1234
SQL_ADMIN_USER="sqladminuser"
KV_NAME="<KEY-VAULT-NAME>"
NAMESPACE="dev"
DEPLOYMENT_NAME="dotnet-helloworld"

NEW_PASSWORD="$(openssl rand -base64 24)"

echo "==> Updating Azure SQL server admin password"
az sql server update -g "$RG" -n "$SQL_SERVER_NAME" --admin-password "$NEW_PASSWORD"

echo "==> Updating Key Vault secret"
az keyvault secret set --vault-name "$KV_NAME" --name "sql-admin-password" --value "$NEW_PASSWORD"

echo "==> Restarting deployment so env-var-based pods pick up the new password"
kubectl rollout restart deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"
kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"

echo "Password rotated and propagated."
