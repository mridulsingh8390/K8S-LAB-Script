# Variant: PostgreSQL running in-cluster with Azure NetApp Files storage

This is an **alternate path** layered onto the main AKS lab — it does not
replace anything in `00-azure-infra.sh` or `k8s/dev/`. It swaps out the
*database layer only*: instead of managed Azure SQL with a Private
Endpoint, PostgreSQL runs as a pod inside the cluster itself, with its
data stored on an Azure NetApp Files (ANF) volume rather than a
managed-service disk. See the main `README.md`'s "Optional variant"
section for the full step-by-step; this file covers the same ground for
when you're working from inside this folder directly.

## Read this before starting: a real limitation, not a configuration detail

The sample app (`HelloWorldApp.web`) used throughout this lab was built
and verified against **SQL Server**. Its actual source code was never
confirmed to use a PostgreSQL-compatible .NET driver (Npgsql) rather than
`Microsoft.Data.SqlClient`. **Changing the connection string format alone
does not make a SQL-Server-oriented .NET app talk to PostgreSQL** — that
requires the app's own code to reference a Postgres driver, which means
editing the source repo and rebuilding the image, not just changing
Kubernetes manifests.

Everything in this variant is correct on the **infrastructure side**:
Postgres genuinely runs, genuinely gets ANF-backed storage, genuinely
receives its password from Key Vault the same way the rest of this lab
does. Whether the *application* actually connects successfully depends
on whether `HelloWorldApp.web`'s code is Postgres-compatible — which is
outside what infrastructure manifests can fix. If you don't control that
source code, you can still validate every infrastructure piece up to "can
a `psql` client reach this database" without ever getting the sample app
itself to successfully query it.

## What's genuinely different from the managed-Azure-SQL path

| Managed Azure SQL (main lab) | In-cluster PostgreSQL (this variant) |
|---|---|
| `az sql server create` — a managed service, Microsoft runs it | `postgres:16` container image, runs as a pod you manage |
| Storage is Microsoft's problem | You own backups, patching, HA, storage — none of that comes free |
| Private Endpoint + private DNS zone | No "endpoint" concept — just a normal Kubernetes Service |
| No StorageClass/PVC needed at all | Needs Astra Trident (a whole separate CSI driver) + a delegated ANF subnet + an ANF account and capacity pool |
| Azure handles failover automatically | A single-replica StatefulSet here has **zero** automatic failover — see the warning in `02-statefulset.yaml` |

This is meaningfully more operational responsibility, not just a
different storage backend — worth knowing before treating this as a
drop-in swap for a real workload.

## Step-by-step

### 1. Prerequisite: the main AKS lab's infra must already exist
```bash
cd ..    # back to the repo root, where 00-azure-infra.sh lives
./00-azure-infra.sh    # if you haven't already run this
```
This variant reuses the VNet, AKS cluster, Key Vault, and resource group
from that script — it reads them out of `.infra-state.env` in the repo
root, not from inside this folder.

### 2. Azure NetApp Files account, capacity pool, delegated subnet
```bash
cd ..
chmod +x 00b-azure-netapp-files.sh
./00b-azure-netapp-files.sh
```
This registers the `Microsoft.NetApp` resource provider (one-time per
subscription), creates a delegated subnet for ANF (required — ANF volumes
cannot live in a non-delegated subnet), creates the ANF account, and
creates a 4 TiB capacity pool (the practical minimum size; you're billed
for the whole pool regardless of how much you actually use inside it,
which is worth knowing if this is just for a POC).

This step does **not** pre-create an individual volume — dynamic
provisioning via Trident (next step) creates volumes on-demand from
PersistentVolumeClaims instead.

### 3. Install Astra Trident (the CSI driver Azure NetApp Files needs)
```bash
chmod +x 01b-install-trident.sh
./01b-install-trident.sh
```
Creates a dedicated Azure service principal for Trident's own Azure API
credentials (separate from AKS's identity, since Trident calls the ANF
management API directly), installs the Trident operator via Helm,
configures its backend to point at your ANF account, and creates the
`azure-netapp-files` StorageClass.

### 4. Store the PostgreSQL password in Key Vault
Not automated — generate a real password and store it yourself, since
Postgres isn't created via an Azure control-plane API call the way Azure
SQL was, so there's no natural point in a script to auto-generate one:
```bash
source .infra-state.env
PG_PASSWORD="$(openssl rand -base64 24)"
az keyvault secret set --vault-name "$KV_NAME" --name "postgres-admin-password" --value "$PG_PASSWORD"
echo "Generated password: $PG_PASSWORD"   # save this somewhere, or re-fetch it from Key Vault later
```

### 5. Fill in placeholders and apply the manifests
Run these from the repo root (one level up from this folder), since
`.infra-state.env` lives there:
```bash
sed -i \
  -e "s|<USER-ASSIGNED-IDENTITY-CLIENT-ID>|$(az identity show -g "$RG" -n id-dotnet-app --query clientId -o tsv)|g" \
  -e "s|<KEY-VAULT-NAME>|${KV_NAME}|g" \
  -e "s|<AZURE-TENANT-ID>|$(az account show --query tenantId -o tsv)|g" \
  dev-postgres-anf/01-secretproviderclass.yaml

sed -i "s|<ACR_NAME>|${ACR_NAME}|g" dev-postgres-anf/03-app-deployment-postgres.yaml

kubectl apply -f dev-postgres-anf/00-pvc.yaml
kubectl apply -f dev-postgres-anf/01-secretproviderclass.yaml
kubectl apply -f dev-postgres-anf/02-statefulset.yaml
```

### 6. Verify Postgres itself is running and reachable, independent of the app
```bash
kubectl get pvc -n dev postgres-data-anf      # should show STATUS: Bound
kubectl get pods -n dev -l app=postgres       # should show 1/1 Running
kubectl exec -n dev postgres-0 -- pg_isready -U postgresadmin
```
This confirms the infrastructure side end-to-end — ANF volume
provisioned, Postgres started, accepting connections — without depending
on the sample app's code being Postgres-compatible at all.

### 7. Only if you've confirmed (or fixed) the app's driver compatibility
```bash
kubectl apply -f dev-postgres-anf/03-app-deployment-postgres.yaml
kubectl logs -n dev deploy/dotnet-helloworld
```
If the app's code is still using `Microsoft.Data.SqlClient`, expect this
to fail at the first real database call (or possibly at startup, if
there's a connection check on boot) with a driver/protocol mismatch error
— that confirms the limitation described at the top of this document, not
a problem with the Kubernetes manifests themselves.

## Tearing this down

```bash
kubectl delete -f dev-postgres-anf/
helm uninstall trident -n trident
kubectl delete namespace trident
az ad sp delete --id "$TRIDENT_CLIENT_ID"
az netappfiles pool delete -g "$RG" -a "$ANF_ACCOUNT_NAME" -p "$ANF_POOL_NAME"
az netappfiles account delete -g "$RG" -a "$ANF_ACCOUNT_NAME"
az network vnet subnet delete -g "$RG" --vnet-name "$VNET_NAME" -n "snet-anf"
```
(Variables come from `.infra-state.env` in the repo root.) The main lab's
`cleanup.sh` does **not** know about any of these ANF-specific resources —
run the above manually before or instead of `cleanup.sh`, or they'll be
left behind (and continue being billed) after the rest of the lab is torn
down.
