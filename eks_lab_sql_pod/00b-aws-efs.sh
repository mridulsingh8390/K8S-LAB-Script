#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00b-aws-efs.sh
# Prerequisite AWS infrastructure for running PostgreSQL IN-CLUSTER on EKS,
# with Amazon EFS as the persistent storage backend, instead of using RDS
# as a managed service.
#
# This is an ALTERNATE PATH alongside the main eks-lab — it does not
# replace anything in 00-aws-infra.sh or the main k8s/dev/ manifests. It
# runs alongside/after the main lab's infra; only the database layer is
# different. The EKS cluster, VPC, Secrets Manager secrets, and ALB
# Ingress from the main lab are all reused unchanged.
#
# What changes vs. the managed RDS approach:
#   RDS SQL Server (managed service)   -> PostgreSQL running as a pod (StatefulSet) in EKS
#   private subnet + security group    -> Amazon EFS, NFS-mounted into the pod via the EFS CSI driver
#   (no separate provisioner needed)   -> aws-efs-csi-driver (a real EKS add-on / Helm install,
#                                          genuinely simpler than AKS's Trident/ANF equivalent -
#                                          no third-party operator, no separate per-cloud service
#                                          principal dance, just IRSA + the official add-on)
#
# Run this AFTER 00-aws-infra.sh has already created the VPC and EKS
# cluster (this script reads VPC_ID, REGION, CLUSTER_NAME from
# .infra-state.env).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ./.infra-state.env ]; then
  echo "ERROR: .infra-state.env not found. Run 00-aws-infra.sh first - this script reuses its VPC and EKS cluster."
  exit 1
fi
source ./.infra-state.env

EFS_NAME="eks-lab-postgres-efs"

wait_for_resource() {
  local check_cmd="$1"
  local label="${2:-resource}"
  local timeout_secs="${3:-180}"
  local interval_secs=10
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
  echo "    ...WARNING: $label did not become ready within ${timeout_secs}s. Continuing anyway."
  return 0
}

echo "==> Creating the EFS file system"
EFS_ID=$(aws efs create-file-system \
  --region "$REGION" \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value="$EFS_NAME" \
  --query "FileSystemId" --output text)

echo "EFS file system ID: $EFS_ID"
wait_for_resource "aws efs describe-file-systems --file-system-id $EFS_ID --region $REGION --query 'FileSystems[0].LifeCycleState' --output text | grep -q available" \
  "EFS file system $EFS_ID" 120

echo "==> Security group allowing NFS (port 2049) from the EKS node security group"
EKS_NODE_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

EFS_SG_ID=$(aws ec2 create-security-group \
  --group-name "eks-lab-efs-sg" \
  --description "Allow NFS traffic from EKS nodes only" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query "GroupId" --output text 2>/dev/null) || \
  EFS_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=eks-lab-efs-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$EFS_SG_ID" \
  --protocol tcp --port 2049 \
  --source-group "$EKS_NODE_SG" \
  --region "$REGION" 2>/dev/null || echo "   (ingress rule already exists, continuing)"

echo "==> Creating a mount target in each private subnet (one per AZ, required for nodes in that AZ to reach EFS)"
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*Private*" \
  --query "Subnets[].SubnetId" --output text)

for subnet_id in $PRIVATE_SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$subnet_id" \
    --security-groups "$EFS_SG_ID" \
    --region "$REGION" 2>/dev/null || echo "   (mount target in $subnet_id already exists, continuing)"
done

echo "============================================================"
echo "DONE. Capture these values:"
echo "  EFS file system ID:  $EFS_ID"
echo "  EFS security group:  $EFS_SG_ID"
echo "============================================================"
echo "Next: run ./01b-install-efs-csi-driver.sh"

cat >> .infra-state.env <<EOF
EFS_ID="$EFS_ID"
EFS_SG_ID="$EFS_SG_ID"
EOF
echo "Appended EFS state to .infra-state.env"
