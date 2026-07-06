# Variant: PostgreSQL running in-cluster with Google Cloud Filestore storage

Basic in-cluster Postgres with CSI driver for Secret Manager password access.
For the TLS + init container version, see `../dev-postgres-filestore-tls/`.

## Why Filestore over the other clouds' storage choices

| Cloud | Storage | Driver type |
|---|---|---|
| AKS | Azure NetApp Files | Third-party (Astra Trident, NetApp) |
| EKS | Amazon EFS | Official AWS driver (Helm) |
| GKE | Google Cloud Filestore | **Built into GKE** (just enable the addon) |

GKE's Filestore CSI driver is a GKE addon — no Helm chart, no separate
operator, no service principal. One `gcloud container clusters update ...
--update-addons=GcpFilestoreCsiDriver=ENABLED` and it's available.

## Important: app driver compatibility

Same caveat as all three clouds' Postgres variants: `HelloWorldApp.web`
was built against SQL Server. Switching to Postgres requires a Npgsql
driver change in the application source code, not just this YAML.

## Step-by-step

```bash
# 1. Run Filestore infra setup (creates instance, enables addon)
./00b-gcp-filestore.sh

# 2. Store the Postgres password in Secret Manager
source .infra-state.env
PG_PASSWORD="$(openssl rand -base64 24)"
gcloud secrets create gke-lab-postgres-password \
  --project "$PROJECT_ID" --replication-policy=automatic
echo -n "$PG_PASSWORD" | gcloud secrets versions add gke-lab-postgres-password \
  --project "$PROJECT_ID" --data-file=-

# Grant the GSA access to the new secret
gcloud secrets add-iam-policy-binding gke-lab-postgres-password \
  --project "$PROJECT_ID" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"

# 3. Fill in placeholders
sed -i \
  -e "s|<PROJECT_ID>|${PROJECT_ID}|g" \
  -e "s|<FILESTORE_IP>|${FILESTORE_IP}|g" \
  -e "s|<FILESTORE_ZONE>|${FILESTORE_ZONE}|g" \
  -e "s|<AR_URI>|${AR_URI}|g" \
  k8s/dev-postgres-filestore/00-pvc.yaml \
  k8s/dev-postgres-filestore/01-secretproviderclass.yaml \
  k8s/dev-postgres-filestore/03-app-deployment-postgres.yaml

# 4. Apply
kubectl apply -f k8s/dev-postgres-filestore/00-pvc.yaml
kubectl apply -f k8s/dev-postgres-filestore/01-secretproviderclass.yaml
kubectl apply -f k8s/dev-postgres-filestore/02-statefulset.yaml

# 5. Verify infrastructure (independent of app compatibility)
kubectl get pvc -n dev postgres-data-filestore
kubectl get pods -n dev -l app=postgres
kubectl exec -n dev postgres-0 -- pg_isready -U postgresadmin

# 6. Apply app deployment only after confirming driver compatibility
kubectl apply -f k8s/dev-postgres-filestore/03-app-deployment-postgres.yaml
```

## Teardown (not covered by main cleanup.sh)
```bash
kubectl delete -f k8s/dev-postgres-filestore/
gcloud filestore instances delete "$FILESTORE_NAME" \
  --project "$PROJECT_ID" --zone "$FILESTORE_ZONE" --quiet
gcloud secrets delete gke-lab-postgres-password --project "$PROJECT_ID" --quiet
```
