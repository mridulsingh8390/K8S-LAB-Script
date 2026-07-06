# Variant: PostgreSQL in-cluster with Init Container (Key Vault) + TLS + Encryption at Rest

This variant extends the basic in-cluster PostgreSQL setup (`dev-postgres-anf/`)
with two additional capabilities:

1. **Init container fetching the password from Key Vault directly** — using the
   pod's Workload Identity and the Key Vault REST API, without the Secrets Store
   CSI driver
2. **TLS in transit** — all connections from the app to Postgres are encrypted
   using certificates managed by cert-manager
3. **Encryption at rest** — via Azure NetApp Files' built-in AES-256 volume
   encryption, plus an explanation of what "TDE for PostgreSQL" actually means
   in practice

---

## Architecture overview

```
App Pod                    Postgres Pod
┌─────────────┐            ┌──────────────────────────────────────┐
│             │            │ Init container 1: fetch-kv-password  │
│             │            │   1. Call IMDS → get bearer token     │
│             │            │   2. Call Key Vault REST API          │
│             │            │   3. Write password to emptyDir(RAM)  │
│             │            ├──────────────────────────────────────┤
│             │            │ Init container 2: fix-cert-permissions│
│             │            │   Copy TLS certs, chmod 0600 key      │
│             │            ├──────────────────────────────────────┤
│ Npgsql      │──TLS/SSL──▶│ Postgres container                   │
│ SSL Mode=   │  encrypted │   Reads password from /vault/password │
│ Require     │            │   ssl = on in postgresql.conf         │
│ + Root cert │            │   hostssl in pg_hba.conf              │
└─────────────┘            └──────────────────────────────────────┘
                                         │
                                         ▼
                            ANF Volume (AES-256 encrypted at rest)
```

---

## Why an init container instead of the CSI driver?

Both approaches work correctly. The choice depends on what you're optimising for:

| | Init Container (this variant) | CSI Driver (dev-postgres-anf/) |
|---|---|---|
| **Dependencies** | Just `curl`, no extra DaemonSet | Requires Secrets Store CSI driver DaemonSet running on every node |
| **Auditability** | Visible in pod logs, reproducible manually | Opaque from the pod's perspective — handled by the DaemonSet |
| **Auto-rotation** | Only at pod restart (re-fetch happens each time the pod starts) | The DaemonSet can refresh the mounted file periodically (`enableSecretRotation=true`) |
| **Secret format** | Raw value — whatever Key Vault returns | Same |
| **Failure mode** | Pod fails to start if Key Vault is unreachable (clear error in init container logs) | Pod stuck in ContainerCreating with a FailedMount event (less obvious) |

For a database password, "fetch at pod startup" is almost always sufficient
since a pod restart is a natural synchronisation point anyway. For a secret
that needs to rotate without a pod restart (e.g. a short-lived API token), the
CSI driver with rotation is the better choice.

---

## How the init container fetches from Key Vault

The `fetch-kv-password` init container does exactly what a human would do
manually to test connectivity, documented in Azure's own Key Vault troubleshooting
guides:

```bash
# Step 1: Get a bearer token using the pod's Workload Identity via IMDS
TOKEN=$(curl -s "http://169.254.169.254/metadata/identity/oauth2/token\
?api-version=2018-02-01\
&resource=https://vault.azure.net\
&client_id=${AZURE_CLIENT_ID}" -H "Metadata: true" | jq -r .access_token)

# Step 2: Call the Key Vault REST API
curl -s "https://${KV_NAME}.vault.azure.net/secrets/postgres-admin-password?api-version=7.4" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r .value
```

The `AZURE_CLIENT_ID` environment variable is **automatically injected** by
the Workload Identity webhook (because the pod has
`azure.workload.identity/use: "true"` and uses `dotnet-app-sa`) — there's
nothing to configure there. The `KV_NAME` comes from the `postgres-tls-app-config`
ConfigMap — you must fill in the `<KEY-VAULT-NAME>` placeholder before applying.

The password is written to an `emptyDir` volume with `medium: Memory` — this
means the password is stored in RAM only and never written to disk or to any
container layer. The Postgres container then reads it via the standard
`POSTGRES_PASSWORD_FILE` environment variable, which the official `postgres:16`
image supports natively.

---

## TLS in transit — what's actually configured

Two things enable TLS in this setup:

**On the Postgres side (server):**
- `postgresql.conf`: `ssl = on`, cert/key paths, `ssl_min_protocol_version = 'TLSv1.2'`
- `pg_hba.conf`: `hostssl` on all remote connections — this **refuses non-encrypted connections** from any client that doesn't use TLS. Local connections (for health checks) still work without TLS.
- cert-manager generates and renews the server certificate automatically

**On the app side (client):**
- Connection string uses `SSL Mode=Require` — Npgsql refuses to connect if the server doesn't offer TLS
- The app mounts the CA cert and passes it as `Root Certificate=` — this means the app **verifies** the server's certificate (not just "use TLS" but "verify this specific server")

**Why the cert-permission init container is needed:**
PostgreSQL is strict about certificate file permissions — it will refuse to
start if the private key file is group- or world-readable. cert-manager mounts
the secret with root ownership and mode 0444 by default. The `fix-cert-permissions`
init container copies the files to a writable `emptyDir` and `chmod`s them to
the exact permissions Postgres requires (0600 for the key, owned by uid 999 —
the `postgres` user inside the container). Without this step, Postgres fails at
startup with `private key file has wrong permissions` or similar.

---

## Encryption at rest — what "TDE for PostgreSQL" actually means

This is worth being honest about, because "TDE for PostgreSQL" means something
genuinely different from "TDE for SQL Server":

**SQL Server TDE:** A built-in engine feature. You run a T-SQL command, SQL
Server encrypts every page it writes to disk transparently. The DEK (data
encryption key) is protected by a master key, optionally stored in Azure Key
Vault.

**PostgreSQL community edition TDE:** The community `postgres:16` image does
**not** have native engine-level page-encryption. There is a `pg_tde` extension
under development, but it was still experimental/not widely available as of mid-2026. The
enterprise fork (EDB Postgres Advanced Server) has actual TDE, but it's a paid
product.

**What this setup provides at rest:** Azure NetApp Files volumes are encrypted
at rest with **AES-256 by default** — every byte written to the volume by
Postgres is encrypted at the storage layer before it reaches disk. This is
functionally equivalent to OS-level or volume-level encryption (like BitLocker
or dm-crypt), not Postgres-engine-level encryption. If someone extracted the
raw ANF volume and bypassed the NFS mount, they would get encrypted data they
cannot read. If someone got shell access to the running Postgres container and
ran `SELECT * FROM`, they would see plaintext data — because the encryption is
below Postgres, not inside it.

**For compliance purposes:** many compliance frameworks (PCI-DSS, ISO 27001,
HIPAA) accept storage-level AES-256 encryption as satisfying their
"encryption at rest" requirement for database storage. Whether it satisfies
*your* specific compliance obligation depends on the framework version and the
auditor — worth checking before treating this as equivalent to SQL Server TDE.

---

## Files in this directory

| File | Purpose |
|---|---|
| `04-cert-manager.yaml` | Instructions and Helm command to install cert-manager |
| `05-postgres-tls-cert.yaml` | Self-signed CA + server TLS certificate via cert-manager |
| `06-postgres-statefulset-tls-initcontainer.yaml` | PostgreSQL StatefulSet with init containers + TLS ConfigMap |
| `07-app-deployment-postgres-tls.yaml` | App Deployment with TLS connection string + CA cert mount |

This directory also depends on files from the parent `dev-postgres-anf/` directory:
- The ANF PVC (`../dev-postgres-anf/00-pvc.yaml`) must already be applied and bound
- The ANF infrastructure (`../../00b-azure-netapp-files.sh`, `../../01b-install-trident.sh`)
  must already have run

---

## Step-by-step

### 1. Prerequisites
All of the original AKS lab infrastructure must exist, plus the ANF setup:
```bash
./00-azure-infra.sh
./00b-azure-netapp-files.sh
./01b-install-trident.sh
```

### 2. Store the PostgreSQL password in Key Vault
```bash
source .infra-state.env
PG_PASSWORD="$(openssl rand -base64 24)"
az keyvault secret set --vault-name "$KV_NAME" --name "postgres-admin-password" --value "$PG_PASSWORD"
```

### 3. Install cert-manager (if not already installed)
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.0 \
  --set crds.enabled=true
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

### 4. Fill in placeholders
```bash
source .infra-state.env
sed -i "s|<KEY-VAULT-NAME>|${KV_NAME}|g" k8s/dev-postgres-anf-tls/07-app-deployment-postgres-tls.yaml
sed -i "s|<ACR_NAME>|${ACR_NAME}|g" k8s/dev-postgres-anf-tls/07-app-deployment-postgres-tls.yaml
```

### 5. Apply in order
```bash
# ANF PVC (if not already applied from dev-postgres-anf/)
kubectl apply -f k8s/dev-postgres-anf/00-pvc.yaml

# TLS certificates
kubectl apply -f k8s/dev-postgres-anf-tls/05-postgres-tls-cert.yaml

# Wait for cert-manager to generate the certificate secret
kubectl wait --for=condition=Ready certificate/postgres-server-cert -n dev --timeout=60s

# ConfigMap and StatefulSet
kubectl apply -f k8s/dev-postgres-anf-tls/07-app-deployment-postgres-tls.yaml   # ConfigMap part
kubectl apply -f k8s/dev-postgres-anf-tls/06-postgres-statefulset-tls-initcontainer.yaml
```

### 6. Verify the init container ran and TLS is working
```bash
# Check init container logs
kubectl logs -n dev postgres-0 -c fetch-kv-password
kubectl logs -n dev postgres-0 -c fix-cert-permissions

# Check Postgres is listening with SSL
kubectl exec -n dev postgres-0 -- psql -U postgresadmin -c "SHOW ssl;"
# Should output: ssl = on

# Verify an SSL connection
kubectl exec -n dev postgres-0 -- psql \
  "sslmode=require host=postgres-svc.dev.svc.cluster.local dbname=appdb user=postgresadmin" \
  -c "\conninfo"
# Should show: SSL connection (protocol: TLSv1.3, ...)
```

### 7. Verify encryption at rest (ANF)
```bash
az netappfiles volume show \
  -g "$RG" \
  --account-name "$ANF_ACCOUNT_NAME" \
  --pool-name "$ANF_POOL_NAME" \
  --name "pgdata" \
  --query "encryptionKeySource" -o tsv
# Should return: Microsoft.NetApp (meaning ANF-managed AES-256 encryption)
```
