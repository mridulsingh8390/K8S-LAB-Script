# AKS + Azure SQL Lab — Setup Guide

## What this covers
1. Dockerfile for `mridulsingh8390/dotnet8` (HelloWorldApp.web)
2. AKS cluster, VNet, private endpoint to Azure SQL, ACR, Key Vault, AGIC — all via `00-azure-infra.sh`
3. Deployment to the `dev` namespace, pulling DB password from Key Vault via the CSI driver
4. NetworkPolicy restricting ping/traffic to the `dev` namespace only
5. AGIC Ingress to expose the app externally
6. A password rotation script for Key Vault

## A note on the Dockerfile
GitHub blocked this tool from browsing past the repo root, so I could see the
solution layout (`HelloWorldApp.sln` + `HelloWorldApp.web/` folder, with a
language mix of HTML/C#/CSS/JS that indicates an ASP.NET Core Razor/MVC app)
but not the actual `.csproj` filename or `Program.cs`. The Dockerfile in
`app/Dockerfile` assumes the conventional `HelloWorldApp.web.csproj` ->
`HelloWorldApp.web.dll`. Before building, clone the repo and check:
```
git clone https://github.com/mridulsingh8390/dotnet8.git
ls dotnet8/HelloWorldApp.web/*.csproj
```
If the csproj or `AssemblyName` differs, update the `ENTRYPOINT` line in the
Dockerfile to match.

## Quickest path: one script

```bash
chmod +x run-all.sh
./run-all.sh
```

This chains everything below: infra → identity federation → placeholder
substitution → image build/push → `kubectl apply`. Expect ~30-40 minutes
total, mostly waiting on AKS/SQL/App Gateway provisioning. Read through it
once before running — it deletes nothing, but it does create real billable
Azure resources.

If anything fails partway through (e.g. a transient `az` timeout), check
the error, fix it, and re-run `./run-all.sh`. Step 1 (`00-azure-infra.sh`)
is not fully idempotent — some `az ... create` calls error on "already
exists" rather than skipping — so a full re-run after a partial failure may
need you to comment out the steps that already succeeded, or just
`az group delete -n rg-aks-lab --yes` for a clean slate and start over.

The sections below describe what `run-all.sh` is doing step by step, in
case you want to run any part manually instead.

## Apply order (manual, if not using run-all.sh)

### 1. Azure infrastructure
```bash
chmod +x 00-azure-infra.sh
./00-azure-infra.sh
```
This prints out the values you need for the placeholders below — capture them.

### 2. Build and push the image
```bash
chmod +x build-and-push.sh
# edit ACR_NAME in build-and-push.sh first
./build-and-push.sh
```

### 3. Set up workload identity federation (required for CSI driver auth)
Run the `az identity create` / `az identity federated-credential create` /
`az keyvault set-policy` commands in the comment block at the top of
`01-serviceaccount.yaml`. `run-all.sh` does this automatically, including
enabling the OIDC issuer / workload identity feature on the cluster if it
isn't already on, and storing the `sql-admin-username` secret in Key Vault
(the infra script only stores `sql-admin-password` by itself).

### 4. Fill in placeholders
Search every file under `k8s/dev/` for `<...>` placeholders and replace with
the values printed by step 1 and the identity created in step 3
(`run-all.sh` does this with `sed` automatically):

| Placeholder | Where | Source |
|---|---|---|
| `<USER-ASSIGNED-IDENTITY-CLIENT-ID>` | 01, 02 | `az identity show --query clientId` |
| `<KEY-VAULT-NAME>` | 02 | infra script output / `.infra-state.env` |
| `<AZURE-TENANT-ID>` | 02 | `az account show --query tenantId` |
| `<SQL_SERVER_NAME>` | 03 | infra script output / `.infra-state.env` |
| `<SQL-PRIVATE-ENDPOINT-IP>` | 03 | infra script output / `.infra-state.env` |
| `<ACR_NAME>` | 04 | infra script output / `.infra-state.env` |

### 5. Apply the manifests
```bash
kubectl apply -f k8s/dev/00-namespace.yaml
kubectl apply -f k8s/dev/01-serviceaccount.yaml
kubectl apply -f k8s/dev/02-secretproviderclass.yaml
kubectl apply -f k8s/dev/03-configmap.yaml
kubectl apply -f k8s/dev/04-deployment-service.yaml
kubectl apply -f k8s/dev/05-networkpolicy.yaml
kubectl apply -f k8s/dev/07-ingress-agic.yaml
```

### 6. Verify DB connectivity
```bash
kubectl get pods -n dev
kubectl logs -n dev deploy/dotnet-helloworld
kubectl exec -n dev deploy/dotnet-helloworld -- env | grep SQL_
```

### 7. Verify ping/NetworkPolicy behavior
```bash
kubectl apply -f k8s/dev/06-network-test-pods.yaml

DEV_IP=$(kubectl get pod -n dev net-test-dev -o jsonpath='{.status.podIP}')

# From a pod inside dev -> should succeed
kubectl exec -n dev net-test-dev -- ping -c 3 "$DEV_IP"

# From a pod outside dev -> should time out / fail
kubectl exec -n other-ns net-test-other -- ping -c 3 "$DEV_IP"
```

### 8. Rotate the SQL password later
```bash
chmod +x rotate-sql-password.sh
# edit placeholders inside the script first
./rotate-sql-password.sh
```

## Why the app connects via private IP/FQDN
The infra script disables public network access on the SQL logical server
and creates a Private Endpoint inside `snet-sql-pe`, linked to a Private DNS
zone (`privatelink.database.windows.net`) that's attached to the VNet. Any
pod in AKS (which uses Azure CNI and lives in the same VNet) resolving
`<server>.database.windows.net` will get back the private IP automatically —
no public internet path is used. The ConfigMap exposes both the FQDN
(recommended) and the literal private IP in case your app config needs the
raw IP specifically.

## Tearing everything down

```bash
chmod +x cleanup.sh
./cleanup.sh
```

This deletes the entire resource group in one shot (AKS, VNet, ACR, Key
Vault, SQL server/database, private endpoint, App Gateway, public IP,
private DNS zone — everything created by `00-azure-infra.sh`/`run-all.sh`
lives inside it). It asks you to type the resource group name to confirm
before deleting anything; pass `./cleanup.sh --yes` to skip that prompt.
Deletion runs in the background (`--no-wait`) and typically takes 15-20+
minutes to fully complete — App Gateway and the SQL private endpoint are
usually the slowest pieces. Check progress with:
```bash
az group exists -n rg-aks-lab
```
This is genuinely destructive — it removes the SQL database and any data
in it along with everything else. There's no undo.
