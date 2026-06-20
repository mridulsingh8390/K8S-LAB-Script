#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh
# Tears down everything created by the eks-lab scripts. Unlike the AKS lab
# (where a single `az group delete` removes everything at once, since
# every resource lives in one resource group), AWS has no equivalent
# single-command teardown across EC2/RDS/IAM/ECR — each service needs its
# own delete call, in an order that respects dependencies (e.g. RDS must
# be deleted before its security group, the EKS cluster's CloudFormation
# stacks handle most of the VPC/node teardown via eksctl, IAM
# roles/policies are global and outlive the cluster unless removed
# explicitly).
#
# WARNING: This is destructive and irreversible. Confirmation prompt
# unless --yes is passed.
#
# Usage:
#   ./cleanup.sh           # interactive
#   ./cleanup.sh --yes     # skip confirmation
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

AUTO_YES="false"
if [ "${1:-}" == "--yes" ]; then
  AUTO_YES="true"
fi

if [ -f ./.infra-state.env ]; then
  source ./.infra-state.env
  echo "==> Loaded state from .infra-state.env"
else
  echo "==> No .infra-state.env found — you'll need to supply these manually below if they're empty."
  REGION="${REGION:-us-east-1}"
  CLUSTER_NAME="${CLUSTER_NAME:-eks-lab-cluster}"
fi

echo "############################################################"
echo "# This will permanently delete:"
echo "#   EKS cluster:       ${CLUSTER_NAME:-<unknown>}"
echo "#   RDS instance:      ${SQL_SERVER_NAME:-<unknown>}"
echo "#   Secrets Manager:   ${SECRET_NAME:-<unknown>}"
echo "#   ECR repo:          ${ECR_REPO_NAME:-<unknown>}"
echo "#   IAM roles/policies created for this lab"
echo "#   VPC, subnets, NAT gateway (via eksctl's CloudFormation stacks)"
echo "############################################################"

if [ "$AUTO_YES" != "true" ]; then
  read -r -p "Type the cluster name to confirm deletion (${CLUSTER_NAME:-eks-lab-cluster}): " CONFIRM
  if [ "$CONFIRM" != "$CLUSTER_NAME" ]; then
    echo "Confirmation did not match. Aborting — nothing was deleted."
    exit 1
  fi
fi

echo "==> Removing local kubectl context (best-effort)"
kubectl config delete-context "$(kubectl config current-context 2>/dev/null)" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Uninstall Helm releases first (so the AWS Load Balancer Controller has
#    a chance to deprovision the ALB cleanly before the cluster disappears —
#    skipping this can orphan the ALB and its security groups/target groups,
#    which then have to be cleaned up manually from the EC2 console).
# ---------------------------------------------------------------------------
echo "==> Deleting Ingress (lets the ALB controller deprovision the ALB cleanly)"
kubectl delete ingress dotnet-helloworld-ingress -n dev 2>/dev/null || true
echo "    waiting 60s for ALB deprovisioning..."
sleep 60

echo "==> Uninstalling Helm releases"
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall csi-secrets-store -n kube-system 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Delete RDS instance (must happen before its security group, and
#    before deleting the cluster if the SG references the cluster SG)
# ---------------------------------------------------------------------------
if [ -n "${SQL_SERVER_NAME:-}" ]; then
  echo "==> Deleting RDS instance: $SQL_SERVER_NAME (skipping final snapshot)"
  aws rds delete-db-instance \
    --db-instance-identifier "$SQL_SERVER_NAME" \
    --skip-final-snapshot \
    --region "$REGION" 2>/dev/null || echo "   (RDS instance not found or already deleting)"

  echo "    ...waiting for RDS instance to finish deleting (can take several minutes)"
  aws rds wait db-instance-deleted --db-instance-identifier "$SQL_SERVER_NAME" --region "$REGION" 2>/dev/null || true
fi

if [ -n "${RDS_SG_ID:-}" ]; then
  echo "==> Deleting RDS security group: $RDS_SG_ID"
  aws ec2 delete-security-group --group-id "$RDS_SG_ID" --region "$REGION" 2>/dev/null || \
    echo "   (security group not found, already deleted, or still has dependencies — clean up manually if so)"
fi

aws rds delete-db-subnet-group --db-subnet-group-name "eks-lab-rds-subnet-group" --region "$REGION" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Delete Secrets Manager secret (force, no recovery window, for clean
#    lab teardown — remove --force-delete-without-recovery if you want the
#    default 7-30 day recovery window instead)
# ---------------------------------------------------------------------------
if [ -n "${SECRET_NAME:-}" ]; then
  echo "==> Deleting Secrets Manager secret: $SECRET_NAME"
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery \
    --region "$REGION" 2>/dev/null || echo "   (secret not found, continuing)"
fi

# ---------------------------------------------------------------------------
# 4. Delete ECR repository (force removes images inside it too)
# ---------------------------------------------------------------------------
if [ -n "${ECR_REPO_NAME:-}" ]; then
  echo "==> Deleting ECR repository: $ECR_REPO_NAME"
  aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --force --region "$REGION" 2>/dev/null || \
    echo "   (repository not found, continuing)"
fi

# ---------------------------------------------------------------------------
# 5. Delete IAM roles/policies created for this lab — these are global
#    (not region-scoped) and will NOT be removed by deleting the cluster.
# ---------------------------------------------------------------------------
echo "==> Cleaning up IAM resources"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

aws iam delete-role-policy --role-name eks-lab-dotnet-app-role --policy-name eks-lab-secrets-read 2>/dev/null || true
aws iam delete-role --role-name eks-lab-dotnet-app-role 2>/dev/null || true

# eksctl's iamserviceaccount for the LB controller creates its own
# CloudFormation-managed role; deleting the cluster (step 6) tears down
# that CFN stack automatically. The IAM *policy* (AWSLoadBalancerControllerIAMPolicy)
# is NOT stack-managed and needs explicit deletion if you want it fully gone:
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" 2>/dev/null || \
  echo "   (AWSLoadBalancerControllerIAMPolicy not found or still attached — eksctl delete cluster below detaches it from its role first)"

# ---------------------------------------------------------------------------
# 6. Delete the EKS cluster (eksctl tears down the VPC, subnets, NAT
#    gateway, node groups, and the iamserviceaccount CFN stacks it created)
# ---------------------------------------------------------------------------
echo "==> Deleting EKS cluster: $CLUSTER_NAME (this takes 10-15+ minutes)"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait 2>/dev/null || \
  echo "   (cluster not found or already deleting)"

if [ -f ./.infra-state.env ]; then
  rm -f ./.infra-state.env
  echo "==> Removed local .infra-state.env"
fi

echo ""
echo "Done. Double-check the EC2/VPC/IAM consoles for any resources this"
echo "script couldn't find by name (e.g. if you edited variables between"
echo "runs) — particularly orphaned ALBs/target groups/security groups,"
echo "which are the most common leftovers if the Ingress deletion step"
echo "above didn't get a chance to fully deprovision before teardown."
