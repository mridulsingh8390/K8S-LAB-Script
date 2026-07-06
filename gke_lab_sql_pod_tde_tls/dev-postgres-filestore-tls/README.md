# Variant: PostgreSQL in-cluster with Init Container (Secret Manager) + TLS + Encryption at Rest

## Init container authentication — simplest of all three clouds

GKE's init container uses the **GCP Metadata Server** — the same approach as
AKS (plain `curl` + Bearer token) but at GCP's endpoint:

```
GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
Header: Metadata-Flavor: Google
→ returns {"access_token": "ya29...", "token_type": "Bearer", ...}

Then:
GET https://secretmanager.googleapis.com/v1/projects/PROJECT/secrets/SECRET/versions/latest:access
Header: Authorization: Bearer <token>
→ returns {"payload": {"data": "<base64-encoded-value>"}}
```

No signing complexity (unlike AWS SigV4), no Azure-specific client_id
parameter — just `Metadata-Flavor: Google` and the secret is yours.
The base64-decoded value is the raw password. This makes the GKE init
container the simplest of all three clouds for this pattern.

**Encryption at rest:** Filestore volumes are encrypted at rest by default
using Google-managed AES-256 keys. No extra configuration needed —
GCP encrypts all data at rest across all its services.

## Files

| File | Purpose |
|---|---|
| `04-postgres-tls-cert-and-statefulset.yaml` | cert-manager certs + ConfigMap + StatefulSet with 2 init containers |
| `05-app-deployment-postgres-tls.yaml` | ConfigMap + App Deployment with TLS connection string |

Depends on: `dev-postgres-filestore/00-pvc.yaml` (PVC must exist)

## Step-by-step

```bash
# 1. Prerequisites
./00b-gcp-filestore.sh

# 2. Store Postgres password in Secret Manager
source .infra-state.env
PG_PASSWORD="$(openssl rand -base64 24)"
gcloud secrets create gke-lab-postgres-password \
  --project "$PROJECT_ID" --replication-policy=automatic 2>/dev/null || true
echo -n "$PG_PASSWORD" | gcloud secrets versions add gke-lab-postgres-password \
  --project "$PROJECT_ID" --data-file=-

# Grant GSA access
gcloud secrets add-iam-policy-binding gke-lab-postgres-password \
  --project "$PROJECT_ID" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"

# 3. Install cert-manager
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.0 --set crds.enabled=true
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s

# 4. Fill in placeholders
sed -i \
  -e "s|<PROJECT_ID>|${PROJECT_ID}|g" \
  -e "s|<AR_URI>|${AR_URI}|g" \
  -e "s|<FILESTORE_IP>|${FILESTORE_IP}|g" \
  -e "s|<FILESTORE_ZONE>|${FILESTORE_ZONE}|g" \
  k8s/dev-postgres-filestore/00-pvc.yaml \
  k8s/dev-postgres-filestore-tls/04-postgres-tls-cert-and-statefulset.yaml \
  k8s/dev-postgres-filestore-tls/05-app-deployment-postgres-tls.yaml

# 5. Apply
kubectl apply -f k8s/dev-postgres-filestore/00-pvc.yaml
kubectl apply -f k8s/dev-postgres-filestore-tls/04-postgres-tls-cert-and-statefulset.yaml
kubectl wait --for=condition=Ready certificate/postgres-server-cert -n dev --timeout=60s

# 6. Verify
kubectl logs -n dev postgres-0 -c fetch-sm-password
kubectl logs -n dev postgres-0 -c fix-cert-permissions
kubectl exec -n dev postgres-0 -- psql -U postgresadmin -c "SHOW ssl;"

# 7. Apply app only after confirming driver compatibility
kubectl apply -f k8s/dev-postgres-filestore-tls/05-app-deployment-postgres-tls.yaml
```

## Teardown
```bash
kubectl delete -f k8s/dev-postgres-filestore-tls/
kubectl delete -f k8s/dev-postgres-filestore/
helm uninstall cert-manager -n cert-manager
gcloud filestore instances delete "$FILESTORE_NAME" \
  --project "$PROJECT_ID" --zone "$FILESTORE_ZONE" --quiet
gcloud secrets delete gke-lab-postgres-password --project "$PROJECT_ID" --quiet
```
