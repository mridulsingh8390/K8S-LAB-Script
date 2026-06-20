#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 00-aws-infra.sh
# Prerequisite AWS infrastructure: VPC (via eksctl), EKS cluster, ECR, RDS
# SQL Server (private subnet, no public access), Secrets Manager, IAM OIDC
# provider (needed for both IRSA and the Secrets Store CSI driver).
#
# This is the AWS/EKS equivalent of the AKS lab's 00-azure-infra.sh. Same
# overall shape, different primitives:
#   Azure VNet/subnets       -> eksctl-managed VPC/subnets
#   AKS                      -> EKS
#   ACR                      -> ECR
#   Azure Key Vault          -> AWS Secrets Manager
#   Azure SQL + Private EP   -> RDS SQL Server in a private subnet, locked
#                                down via security groups (no AWS service
#                                provides a literal "private endpoint" for
#                                RDS the way Azure Private Link does for
#                                SQL — same-VPC + private subnet + SG rules
#                                is the standard, AWS-documented pattern)
#   AGIC                     -> AWS Load Balancer Controller (installed in
#                                01-aws-lbc-and-identity.sh, not here, since
#                                it needs the OIDC provider this script sets
#                                up first)
#
# Requires: aws CLI v2, eksctl, kubectl, jq — all configured/authenticated
# (aws configure or equivalent) before running.
#
# Run this BEFORE 01-aws-lbc-and-identity.sh and before any kubectl apply.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- Variables: EDIT THESE ----
REGION="us-east-1"               # change if you hit capacity/availability issues, same as we did on Azure
CLUSTER_NAME="eks-lab-cluster"
VPC_CIDR="10.20.0.0/16"

ECR_REPO_NAME="dotnet-helloworld"
SQL_SERVER_NAME="sqlsrv-eks-lab-$RANDOM"   # used as the RDS instance identifier (lowercase, no underscores allowed)
SQL_DB_NAME="appdb"
SQL_ADMIN_USER="sqladmin"          # 'admin' is a reserved word for SQL Server on RDS — cannot be used
SQL_ADMIN_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-30)"  # RDS SQL Server has stricter password char rules than Azure SQL

SECRET_NAME="eks-lab/sql-credentials"   # AWS Secrets Manager secret name

# ---------------------------------------------------------------------------
# wait_for_resource: generic poll loop, same purpose as the AKS lab's
# version — closes propagation races between resource creation and the
# next command that depends on it being fully queryable. AWS APIs are
# generally more consistent about this than Azure's, but RDS and Secrets
# Manager in particular can still lag a few seconds right after creation.
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
  echo "    ...WARNING: $label did not become ready within ${timeout_secs}s. Continuing anyway — re-run later steps if they fail with a not-found error."
  return 0
}

echo "==> Confirming AWS CLI identity (sanity check before creating anything)"
aws sts get-caller-identity --query Account --output text

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ---------------------------------------------------------------------------
# Guard against resuming into a partially-completed previous run — same
# rationale as the AKS lab's guard. eksctl/CloudFormation stacks are even
# less forgiving of partial state than Azure resource groups, so this check
# matters at least as much here.
# ---------------------------------------------------------------------------
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo ""
  echo "WARNING: an EKS cluster named '$CLUSTER_NAME' already exists in $REGION."
  echo "This script is not safe to resume on top of partially-created infra."
  echo ""
  read -r -p "Continue anyway? Only do this if you're sure it's compatible (y/N): " CONTINUE_ANYWAY
  if [ "$CONTINUE_ANYWAY" != "y" ] && [ "$CONTINUE_ANYWAY" != "Y" ]; then
    echo "Aborting. Recommended: ./cleanup.sh   (wait for it to fully finish), then re-run."
    exit 1
  fi
fi

echo "==> EKS cluster + managed VPC (eksctl provisions the VPC, subnets, NAT gateway, IAM roles in one step)"
# --node-type / --nodes mirror the AKS lab's 2-node default pool. eksctl
# creates 2 public + 2 private subnets across 2 AZs by default, plus a NAT
# gateway for the private subnets' outbound traffic. The RDS instance is
# placed in the private subnets later in this script.
eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --vpc-cidr "$VPC_CIDR" \
  --version "1.31" \
  --nodegroup-name standard-workers \
  --node-type m5.large \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 2 \
  --managed \
  --with-oidc

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "==> dev namespace"
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace dev environment=dev --overwrite

echo "==> ECR repository"
aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$REGION" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$REGION"

ECR_URI=$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$REGION" \
  --query "repositories[0].repositoryUri" --output text)

# ---------------------------------------------------------------------------
# RDS SQL Server — the AWS analog to Azure SQL's private endpoint.
#
# IMPORTANT DIFFERENCE FROM THE AKS LAB: Azure SQL with a Private Endpoint
# gets its OWN dedicated private IP via Azure Private Link, in a dedicated
# subnet, with a private DNS zone resolving the public-looking FQDN to that
# private IP. AWS has no equivalent "Private Link for RDS" primitive in
# the same sense — the standard, AWS-documented pattern (confirmed via
# AWS's own EKS+RDS connectivity guidance) is simpler: put RDS in a
# private subnet (no public IP, no internet route), put it in the SAME VPC
# as EKS, and use a Security Group to allow inbound only from the EKS
# node security group. There's no separate "endpoint" resource — the
# RDS instance's own private DNS endpoint (e.g. sqlsrv-xxx.xxxx.rds.amazonaws.com)
# already resolves to a private IP automatically as long as the instance
# itself has no public accessibility, which we enforce below with
# --no-publicly-accessible.
# ---------------------------------------------------------------------------

echo "==> Locating the VPC and private subnets eksctl created"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

# eksctl tags its private subnets distinctly; filter on that tag rather than
# guessing by CIDR, since eksctl's subnet allocation within VPC_CIDR isn't
# fixed across versions.
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*Private*" \
  --query "Subnets[].SubnetId" --output text | tr '\t' ',')

if [ -z "$PRIVATE_SUBNET_IDS" ]; then
  echo "ERROR: could not find private subnets tagged by eksctl. Check 'aws ec2 describe-subnets' manually and set PRIVATE_SUBNET_IDS by hand if needed."
  exit 1
fi
echo "Private subnets for RDS: $PRIVATE_SUBNET_IDS"

echo "==> RDS DB subnet group (must span at least 2 AZs)"
# shellcheck disable=SC2046
# Intentionally unquoted: --subnet-ids expects multiple separate
# space-delimited arguments (subnet-1 subnet-2 ...), not one string.
aws rds create-db-subnet-group \
  --db-subnet-group-name "eks-lab-rds-subnet-group" \
  --db-subnet-group-description "Private subnets for eks-lab RDS SQL Server" \
  --subnet-ids $(echo "$PRIVATE_SUBNET_IDS" | tr ',' ' ') \
  --region "$REGION" 2>/dev/null || echo "   (subnet group already exists, continuing)"

echo "==> Security group for RDS: allow inbound 1433 from EKS node security group only"
EKS_NODE_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name "eks-lab-rds-sg" \
  --description "Allow SQL Server traffic from EKS nodes only" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query "GroupId" --output text 2>/dev/null) || \
  RDS_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=eks-lab-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG_ID" \
  --protocol tcp --port 1433 \
  --source-group "$EKS_NODE_SG" \
  --region "$REGION" 2>/dev/null || echo "   (ingress rule already exists, continuing)"

echo "==> RDS SQL Server instance (db.t3.small, no public access — private subnet only)"
# sqlserver-ex (Express edition) keeps this free-tier-eligible for a POC;
# switch to sqlserver-se/sqlserver-web if you need features Express lacks.
aws rds create-db-instance \
  --db-instance-identifier "$SQL_SERVER_NAME" \
  --db-instance-class db.t3.small \
  --engine sqlserver-ex \
  --master-username "$SQL_ADMIN_USER" \
  --master-user-password "$SQL_ADMIN_PASS" \
  --allocated-storage 20 \
  --db-subnet-group-name "eks-lab-rds-subnet-group" \
  --vpc-security-group-ids "$RDS_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --backup-retention-period 1 \
  --region "$REGION"

echo "    ...waiting for RDS instance to become available (this typically takes 10-15 minutes)"
aws rds wait db-instance-available --db-instance-identifier "$SQL_SERVER_NAME" --region "$REGION"

SQL_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$SQL_SERVER_NAME" --region "$REGION" \
  --query "DBInstances[0].Endpoint.Address" --output text)
SQL_PORT=$(aws rds describe-db-instances --db-instance-identifier "$SQL_SERVER_NAME" --region "$REGION" \
  --query "DBInstances[0].Endpoint.Port" --output text)

echo "SQL endpoint (resolves to a private IP from inside the VPC, since the instance has no public accessibility): $SQL_ENDPOINT:$SQL_PORT"

# NOTE: RDS SQL Server (unlike Azure SQL) does not let you create the
# application database via the API at instance-creation time the same way
# `az sql db create` does — you connect with a SQL client and run
# `CREATE DATABASE appdb;` yourself once the instance is available, or via
# an init job. See README for the exact command.

echo "==> Storing SQL credentials in AWS Secrets Manager"
aws secretsmanager create-secret \
  --name "$SECRET_NAME" \
  --description "RDS SQL Server admin credentials for eks-lab" \
  --secret-string "{\"username\":\"$SQL_ADMIN_USER\",\"password\":\"$SQL_ADMIN_PASS\",\"host\":\"$SQL_ENDPOINT\",\"port\":\"$SQL_PORT\",\"dbname\":\"$SQL_DB_NAME\"}" \
  --region "$REGION" 2>/dev/null || \
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "{\"username\":\"$SQL_ADMIN_USER\",\"password\":\"$SQL_ADMIN_PASS\",\"host\":\"$SQL_ENDPOINT\",\"port\":\"$SQL_PORT\",\"dbname\":\"$SQL_DB_NAME\"}" \
    --region "$REGION"

SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" \
  --query "ARN" --output text)

echo "============================================================"
echo "DONE. Capture these values:"
echo "  Region:               $REGION"
echo "  EKS cluster:          $CLUSTER_NAME"
echo "  ECR repo URI:         $ECR_URI"
echo "  RDS endpoint:         $SQL_ENDPOINT:$SQL_PORT"
echo "  RDS admin user:       $SQL_ADMIN_USER"
echo "  Secrets Manager ARN:  $SECRET_ARN"
echo "  VPC ID:                $VPC_ID"
echo "============================================================"
echo ""
echo "NEXT STEP (not done by this script): create the application database."
echo "From a machine that can reach the VPC (e.g. exec into a pod with sqlcmd,"
echo "see README section 'Creating the application database'), run:"
echo "  CREATE DATABASE $SQL_DB_NAME;"
echo ""
echo "Then run ./01-aws-lbc-and-identity.sh next."

# ---------------------------------------------------------------------------
# State file, same purpose as the AKS lab's .infra-state.env
# ---------------------------------------------------------------------------
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.infra-state.env"
cat > "$STATE_FILE" <<EOF
REGION="$REGION"
CLUSTER_NAME="$CLUSTER_NAME"
ACCOUNT_ID="$ACCOUNT_ID"
ECR_REPO_NAME="$ECR_REPO_NAME"
ECR_URI="$ECR_URI"
SQL_SERVER_NAME="$SQL_SERVER_NAME"
SQL_DB_NAME="$SQL_DB_NAME"
SQL_ADMIN_USER="$SQL_ADMIN_USER"
SQL_ENDPOINT="$SQL_ENDPOINT"
SQL_PORT="$SQL_PORT"
SECRET_NAME="$SECRET_NAME"
SECRET_ARN="$SECRET_ARN"
VPC_ID="$VPC_ID"
RDS_SG_ID="$RDS_SG_ID"
EOF
echo "State written to: $STATE_FILE"
