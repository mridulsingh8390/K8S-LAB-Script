# Variant: PostgreSQL running in-cluster with Amazon EFS storage

This is an **alternate path** layered onto the main EKS lab — it does not
replace anything in `00-aws-infra.sh` or `k8s/dev/`. It swaps out the
*database layer only*: instead of managed RDS SQL Server with a private
subnet + security group, PostgreSQL runs as a pod inside the cluster
itself, with its data stored on Amazon EFS rather than RDS's managed
storage. See the main `README.md`'s "Optional variant" section for the
same content; this file covers the same ground for when you're working
from inside this folder directly.

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
Postgres genuinely runs, genuinely gets EFS-backed storage, genuinely
receives its password from Secrets Manager the same way the rest of this
lab does. Whether the *application* actually connects successfully
depends on whether `HelloWorldApp.web`'s code is Postgres-compatible —
which is outside what infrastructure manifests can fix. If you don't
control that source code, you can still validate every infrastructure
piece up to "can a `psql` client reach this database" without ever
getting the sample app itself to successfully query it.

## What's genuinely different from the managed-RDS path

| Managed RDS (main lab) | In-cluster PostgreSQL (this variant) |
|---|---|
| `aws rds create-db-instance` — a managed service, AWS runs it | `postgres:16` container image, runs as a pod you manage |
| Storage is AWS's problem | You own backups, patching, HA, storage — none of that comes free |
| Private subnet + security group | No "endpoint" concept — just a normal Kubernetes Service |
| No StorageClass/PVC needed at all | Needs the EFS CSI driver (IRSA + Helm) + an EFS file system + mount targets per AZ |
| AWS handles failover automatically (if Multi-AZ) | A single-replica StatefulSet here has **zero** automatic failover — see the warning in `02-statefulset.yaml` |

This is meaningfully more operational responsibility, not just a
different storage backend — worth knowing before treating this as a
drop-in swap for a real workload.

## Why this is simpler than the AKS lab's equivalent variant

The AKS lab's database-in-cluster variant uses Azure NetApp Files, which
needs a third-party CSI driver (Astra Trident, from NetApp, not
Microsoft), its own dedicated service principal, a delegated subnet, an
ANF account, and a capacity pool billed by pool size regardless of usage.
EFS's path is genuinely lighter: the EFS CSI driver is AWS's own
officially maintained driver, installed via a normal Helm chart using
IRSA — the exact same identity mechanism already used everywhere else in
this lab series — with no third-party operator and no extra credentials
to manage. This isn't a stylistic difference; it's fewer moving parts and
fewer things that can drift out of sync.

## Step-by-step

### 1. Prerequisite: the main EKS lab's infra must already exist
```bash
cd ..    # back to the repo root, where 00-aws-infra.sh lives
./00-aws-infra.sh    # if you haven't already run this
```
This variant reuses the VPC, EKS cluster, and IAM setup from that script
— it reads them out of `.infra-state.env` in the repo root.

### 2. EFS file system, mount targets, security group
```bash
cd ..
chmod +x 00b-aws-efs.sh
./00b-aws-efs.sh
```
Creates an encrypted EFS file system, a security group allowing NFS
(port 2049) from the EKS node security group only, and a mount target in
each private subnet (one per AZ — required for nodes in that AZ to
actually reach EFS; without a mount target in its own AZ, a node's NFS
traffic would have to cross AZ boundaries, adding latency and, in some
configurations, failing outright).

### 3. Install the EFS CSI driver
```bash
chmod +x 01b-install-efs-csi-driver.sh
./01b-install-efs-csi-driver.sh
```
Creates an IRSA-bound ServiceAccount for the driver's controller, installs
the driver via Helm, and creates the `efs-sc` StorageClass using
access-point-based dynamic provisioning against the file system from step 2.

### 4. Store the PostgreSQL password in Secrets Manager
Not automated — generate a real password and store it yourself, since
Postgres isn't created via an AWS control-plane API call the way RDS was:
```bash
source .infra-state.env
PG_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-30)"
aws secretsmanager create-secret --name eks-lab/postgres-admin-password \
  --secret-string "$PG_PASSWORD" --region "$REGION"
PG_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id eks-lab/postgres-admin-password \
  --region "$REGION" --query ARN --output text)
echo "Secret ARN: $PG_SECRET_ARN"
```

### 5. Fill in placeholders and apply the manifests
Run these from the repo root (one level up from this folder), since
`.infra-state.env` lives there:
```bash
sed -i "s|<POSTGRES-SECRET-ARN>|${PG_SECRET_ARN}|g" dev-postgres-efs/01-secretproviderclass.yaml
sed -i "s|<ECR_URI>|${ECR_URI}|g" dev-postgres-efs/03-app-deployment-postgres.yaml

kubectl apply -f dev-postgres-efs/00-pvc.yaml
kubectl apply -f dev-postgres-efs/01-secretproviderclass.yaml
kubectl apply -f dev-postgres-efs/02-statefulset.yaml
```

### 6. Verify Postgres itself is running and reachable, independent of the app
```bash
kubectl get pvc -n dev postgres-data-efs       # should show STATUS: Bound
kubectl get pods -n dev -l app=postgres        # should show 1/1 Running
kubectl exec -n dev postgres-0 -- pg_isready -U postgresadmin
```
This confirms the infrastructure side end-to-end — EFS access point
provisioned, Postgres started, accepting connections — without depending
on the sample app's code being Postgres-compatible at all.

### 7. Only if you've confirmed (or fixed) the app's driver compatibility
```bash
kubectl apply -f dev-postgres-efs/03-app-deployment-postgres.yaml
kubectl logs -n dev deploy/dotnet-helloworld
```
If the app's code is still using `Microsoft.Data.SqlClient`, expect this
to fail at the first real database call (or possibly at startup) with a
driver/protocol mismatch error — that confirms the limitation described
at the top of this document, not a problem with the Kubernetes manifests
themselves.

## Tearing this down

```bash
kubectl delete -f dev-postgres-efs/
helm uninstall aws-efs-csi-driver -n kube-system
eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace kube-system --name efs-csi-controller-sa
aws secretsmanager delete-secret --secret-id eks-lab/postgres-admin-password --force-delete-without-recovery --region "$REGION"
for mt in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$REGION" --query "MountTargets[].MountTargetId" --output text); do
  aws efs delete-mount-target --mount-target-id "$mt" --region "$REGION"
done
sleep 15
aws efs delete-file-system --file-system-id "$EFS_ID" --region "$REGION"
aws ec2 delete-security-group --group-id "$EFS_SG_ID" --region "$REGION"
```
(Variables come from `.infra-state.env` in the repo root.) The mount
targets must be deleted before the file system itself, and the security
group must be deleted after the file system (since the file system's
mount targets depend on it) — the `sleep 15` gives AWS a moment to finish
detaching mount targets before the file system delete call. The main
lab's `cleanup.sh` does **not** know about any of these EFS-specific
resources — run the above manually before or instead of `cleanup.sh`, or
they'll be left behind (and continue being billed) after the rest of the
lab is torn down.
