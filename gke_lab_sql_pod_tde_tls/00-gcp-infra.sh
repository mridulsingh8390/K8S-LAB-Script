#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-gcp-infra.sh
# Prerequisite GCP infrastructure: VPC + subnet, GKE cluster (Dataplane V2
# enabled at creation, Workload Identity Federation enabled), Artifact
# Registry, Cloud SQL for SQL Server (private IP only, via Private Service
# Access), Secret Manager.
#
# This is the GKE equivalent of the AKS lab's 00-azure-infra.sh and the EKS
# lab's 00-aws-infra.sh. Same overall shape, GCP-native primitives:
#   Azure VNet/subnets, AWS VPC  -> GCP VPC + subnet
#   AKS / EKS                    -> GKE
#   ACR / ECR                    -> Artifact Registry
#   Azure Key Vault /
#     AWS Secrets Manager        -> GCP Secret Manager
#   Azure SQL Private Endpoint /
#     RDS in private subnet+SG   -> Cloud SQL for SQL Server, private IP via
#                                    Private Service Access (PSA) - GCP's own
#                                    distinct mechanism: a dedicated IP range
#                                    is peered to Google's service-producer
#                                    network, and Cloud SQL gets an IP from
#                                    that range. Neither a literal "private
#                                    endpoint" resource (Azure) nor a plain
#                                    "private subnet + security group"
#                                    pattern (AWS) - genuinely a third shape.
#   Azure AD Workload Identity /
#     IRSA                        -> Workload Identity Federation for GKE
#   Calico / VPC CNI native mode  -> GKE Dataplane V2 (enabled at cluster
#                                    creation, NOT a retrofit - NetworkPolicy
#                                    enforcement is built into the data path
#                                    from the start, which is structurally
#                                    why this avoids the EKS lab's incident
#                                    class of risk: there's no "enable this
#                                    on an already-running CNI" step at all)
#   AGIC / AWS Load Balancer
#     Controller                  -> GKE Ingress (GCE Ingress Controller),
#                                    installed in 01-gke-identity-and-sql.sh
#
# Requires: gcloud CLI, kubectl, authenticated (gcloud auth login or
# equivalent) and a GCP project selected (gcloud config set project) before
# running.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Variables: EDIT THESE ----
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="us-central1"
ZONE="us-central1-a"
CLUSTER_NAME="gke-lab-cluster"

VPC_NAME="gke-lab-vpc"
SUBNET_NAME="gke-lab-subnet"
SUBNET_CIDR="10.30.0.0/20"
PODS_RANGE_NAME="gke-lab-pods"
PODS_CIDR="10.31.0.0/16"
SERVICES_RANGE_NAME="gke-lab-services"
SERVICES_CIDR="10.32.0.0/20"
PSA_RANGE_NAME="gke-lab-psa-range"
PSA_CIDR="10.33.0.0/16"   # for Private Service Access (Cloud SQL private IP)

AR_REPO_NAME="dotnet-helloworld"
SQL_INSTANCE_NAME="sqlsrv-gke-lab-${RANDOM}"
SQL_DB_NAME="appdb"
SQL_ADMIN_USER="sqlserver"   # 'sqlserver', 'admin', 'root' are reserved on some engines - this one is accepted for SQL Server on Cloud SQL
SQL_ADMIN_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-30)"

SQL_SECRET_IDS="gke-lab-sql-username,gke-lab-sql-password,gke-lab-sql-host,gke-lab-sql-port,gke-lab-sql-dbname"

# ---------------------------------------------------------------------------
# wait_for_resource: same generic poll-loop pattern used in the AKS/EKS labs,
# closing propagation races between resource creation and the next command
# that depends on it. gcloud operations are generally synchronous (the CLI
# blocks until done) more often than Azure's or AWS's equivalents, but the
# Private Service Access peering and Cloud SQL instance readiness can still
# lag slightly behind the CLI returning.
# ---------------------------------------------------------------------------
wait_for_resource() {
  local check_cmd="$1"
  local label="${2:-resource}"
  local timeout_secs="${3:-300}"
  local interval_secs=5
  local elapsed=0

  echo "    ...waiting for $label (timeout ${timeout_secs}s)"
  while [ "$elapsed" -lt "$timeout_secs" ]; do
    if eval "$check_cmd" >/dev/null 2>&1; then
      echo "    ...$label is ready after ${elapsed}s"
      return 0
    fi
    sleep "$interval_secs"
    elapsed=$((elapsed + interval_secs))
  done
  echo "    ...WARNING: $label did not become ready within ${timeout_secs}s. Continuing anyway - re-run later steps if they fail with a not-found error."
  return 0
}

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: no GCP project set. Run 'gcloud config set project <your-project-id>' first, or export PROJECT_ID=<your-project-id>."
  exit 1
fi
echo "==> Using GCP project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

# ---------------------------------------------------------------------------
# Guard against resuming into a partially-completed previous run - same
# rationale as the AKS/EKS labs' guards.
# ---------------------------------------------------------------------------
if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo ""
  echo "WARNING: a GKE cluster named '$CLUSTER_NAME' already exists in $ZONE."
  echo "This script is not safe to resume on top of partially-created infra."
  echo ""
  read -r -p "Continue anyway? Only do this if you're sure it's compatible (y/N): " CONTINUE_ANYWAY
  if [ "$CONTINUE_ANYWAY" != "y" ] && [ "$CONTINUE_ANYWAY" != "Y" ]; then
    echo "Aborting. Recommended: ./cleanup.sh   (wait for it to fully finish), then re-run."
    exit 1
  fi
fi

echo "==> Enabling required GCP APIs (no-op if already enabled)"
gcloud services enable \
  container.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  --project "$PROJECT_ID"

echo "==> VPC"
gcloud compute networks create "$VPC_NAME" \
  --project "$PROJECT_ID" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional 2>/dev/null || echo "   (VPC already exists, continuing)"

echo "==> Subnet (with secondary ranges for GKE pods/services)"
gcloud compute networks subnets create "$SUBNET_NAME" \
  --project "$PROJECT_ID" \
  --network="$VPC_NAME" \
  --region="$REGION" \
  --range="$SUBNET_CIDR" \
  --secondary-range="${PODS_RANGE_NAME}=${PODS_CIDR}" \
  --secondary-range="${SERVICES_RANGE_NAME}=${SERVICES_CIDR}" 2>/dev/null || \
  echo "   (subnet already exists, continuing)"

echo "==> Firewall rule: allow internal traffic within the VPC (GKE control plane, pod-to-pod, etc.)"
gcloud compute firewall-rules create "${VPC_NAME}-allow-internal" \
  --project "$PROJECT_ID" \
  --network="$VPC_NAME" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp,udp,icmp \
  --source-ranges="${SUBNET_CIDR},${PODS_CIDR},${SERVICES_CIDR}" 2>/dev/null || \
  echo "   (firewall rule already exists, continuing)"

echo "==> GKE cluster (Dataplane V2 + Workload Identity Federation enabled at creation)"
# --enable-dataplane-v2: NetworkPolicy enforcement built into the data path
#   from cluster creation - not a retrofit, see the comment block at the top
#   of this file for why that matters.
# --workload-pool: enables Workload Identity Federation for GKE (the IRSA
#   equivalent) at the cluster level; individual KSA<->GSA bindings happen
#   later in 01-gke-identity-and-sql.sh.
gcloud container clusters create "$CLUSTER_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --network="$VPC_NAME" \
  --subnetwork="$SUBNET_NAME" \
  --cluster-secondary-range-name="$PODS_RANGE_NAME" \
  --services-secondary-range-name="$SERVICES_RANGE_NAME" \
  --enable-ip-alias \
  --enable-dataplane-v2 \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --num-nodes=2 \
  --machine-type=e2-standard-2 \
  --release-channel=regular

gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID"

echo "==> dev namespace"
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace dev environment=dev --overwrite

echo "==> Artifact Registry repository"
gcloud artifacts repositories create "$AR_REPO_NAME" \
  --project "$PROJECT_ID" \
  --repository-format=docker \
  --location="$REGION" 2>/dev/null || echo "   (repository already exists, continuing)"

AR_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO_NAME}/dotnet-helloworld"

# ---------------------------------------------------------------------------
# Private Service Access (PSA) for Cloud SQL private IP - GCP's distinct
# mechanism, different from both Azure's Private Link and AWS's plain
# private-subnet-plus-security-group pattern. This allocates a dedicated IP
# range and peers it to Google's service-producer VPC; Cloud SQL then draws
# its private IP from that range. This only needs to be done once per VPC.
# ---------------------------------------------------------------------------
echo "==> Allocating IP range for Private Service Access"
gcloud compute addresses create "$PSA_RANGE_NAME" \
  --project "$PROJECT_ID" \
  --global \
  --purpose=VPC_PEERING \
  --addresses="$(echo "$PSA_CIDR" | cut -d'/' -f1)" \
  --prefix-length="$(echo "$PSA_CIDR" | cut -d'/' -f2)" \
  --network="$VPC_NAME" 2>/dev/null || echo "   (PSA range already exists, continuing)"

echo "==> Creating the VPC peering connection for Private Service Access"
gcloud services vpc-peerings connect \
  --project "$PROJECT_ID" \
  --service=servicenetworking.googleapis.com \
  --ranges="$PSA_RANGE_NAME" \
  --network="$VPC_NAME" 2>/dev/null || echo "   (peering connection already exists, continuing)"

echo "==> Cloud SQL for SQL Server instance (private IP only, no public IP)"
gcloud sql instances create "$SQL_INSTANCE_NAME" \
  --project "$PROJECT_ID" \
  --database-version=SQLSERVER_2019_STANDARD \
  --tier=db-custom-2-7680 \
  --region="$REGION" \
  --network="projects/${PROJECT_ID}/global/networks/${VPC_NAME}" \
  --no-assign-ip \
  --root-password="$SQL_ADMIN_PASS"

echo "    ...waiting for the Cloud SQL instance to report RUNNABLE"
wait_for_resource \
  "gcloud sql instances describe $SQL_INSTANCE_NAME --project $PROJECT_ID --format='value(state)' | grep -q RUNNABLE" \
  "Cloud SQL instance $SQL_INSTANCE_NAME" \
  600

SQL_PRIVATE_IP=$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --project "$PROJECT_ID" \
  --format="value(ipAddresses[0].ipAddress)")
echo "Cloud SQL private IP: $SQL_PRIVATE_IP"

echo "==> Creating the application database"
gcloud sql databases create "$SQL_DB_NAME" --instance="$SQL_INSTANCE_NAME" --project "$PROJECT_ID"

echo "==> Storing SQL credentials in Secret Manager as 5 separate secrets"
# DIFFERENCE FROM THE EKS LAB: that lab stored one combined JSON secret and
# used the AWS provider's jmesPath feature to split it back out. The GCP
# provider for the Secrets Store CSI Driver doesn't have an equivalent
# JSON-path-splitting feature in its `secrets:` parameter the same way, so
# this lab stores each field as its own Secret Manager secret instead -
# directly mirroring how Azure Key Vault stores 5 separate secrets in the
# AKS lab. This also means the per-secret IAM grant in
# 01-gke-identity-and-sql.sh needs to cover all 5, not just one.
declare -A SQL_SECRET_VALUES=(
  ["gke-lab-sql-username"]="${SQL_ADMIN_USER}"
  ["gke-lab-sql-password"]="${SQL_ADMIN_PASS}"
  ["gke-lab-sql-host"]="${SQL_PRIVATE_IP}"
  ["gke-lab-sql-port"]="1433"
  ["gke-lab-sql-dbname"]="${SQL_DB_NAME}"
)

for secret_id in "${!SQL_SECRET_VALUES[@]}"; do
  gcloud secrets create "$secret_id" --project "$PROJECT_ID" --replication-policy=automatic 2>/dev/null || \
    echo "   (secret $secret_id already exists, continuing)"
  echo -n "${SQL_SECRET_VALUES[$secret_id]}" | gcloud secrets versions add "$secret_id" --project "$PROJECT_ID" --data-file=-
done

echo "============================================================"
echo "DONE. Capture these values:"
echo "  Project ID:           $PROJECT_ID"
echo "  Region/Zone:          $REGION / $ZONE"
echo "  GKE cluster:          $CLUSTER_NAME"
echo "  Artifact Registry:    $AR_URI"
echo "  Cloud SQL instance:   $SQL_INSTANCE_NAME"
echo "  Cloud SQL private IP: $SQL_PRIVATE_IP"
echo "  Cloud SQL admin user: $SQL_ADMIN_USER"
echo "  Secret Manager IDs:   $SQL_SECRET_IDS"
echo "  VPC:                  $VPC_NAME"
echo "============================================================"
echo "Next: run ./01-gke-identity-and-sql.sh"

# ---------------------------------------------------------------------------
# State file, same purpose as the AKS/EKS labs' .infra-state.env
# ---------------------------------------------------------------------------
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.infra-state.env"
cat > "$STATE_FILE" <<EOF
PROJECT_ID="$PROJECT_ID"
REGION="$REGION"
ZONE="$ZONE"
CLUSTER_NAME="$CLUSTER_NAME"
VPC_NAME="$VPC_NAME"
SUBNET_NAME="$SUBNET_NAME"
AR_REPO_NAME="$AR_REPO_NAME"
AR_URI="$AR_URI"
SQL_INSTANCE_NAME="$SQL_INSTANCE_NAME"
SQL_DB_NAME="$SQL_DB_NAME"
SQL_ADMIN_USER="$SQL_ADMIN_USER"
SQL_PRIVATE_IP="$SQL_PRIVATE_IP"
SQL_SECRET_IDS="$SQL_SECRET_IDS"
EOF
echo "State written to: $STATE_FILE"
