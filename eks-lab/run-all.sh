#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-all.sh
# End-to-end orchestrator for the EKS lab — same role as the AKS lab's
# run-all.sh. Run this ONE script from the eks-lab/ directory and it will:
#   1. Run 00-aws-infra.sh (VPC/EKS/ECR/RDS/Secrets Manager)
#   2. Run 01-aws-lbc-and-identity.sh (IRSA, CSI driver, ALB controller, Calico)
#   3. Substitute every <PLACEHOLDER> in the k8s YAML and helper scripts
#   4. Build and push the dotnet image to ECR
#   5. kubectl apply everything in the correct order
#   6. Print a summary + the verification commands to run
#
# Run it as:  ./run-all.sh
#
# IMPORTANT: this does NOT create the application database inside the RDS
# instance (RDS, unlike Azure SQL, has no API call equivalent to
# `az sql db create` for SQL Server engines — you connect and run
# CREATE DATABASE yourself). Step 1 prints the exact command; do this
# before applying the Kubernetes manifests in step 5, or the app will
# connect successfully but fail on its first real query.
#
# Re-running: like the AKS lab, steps 1-2 are not fully idempotent across a
# full re-run from a totally clean slate vs. a partial failure. If you need
# to retry after a partial failure, prefer fixing forward over re-running
# from scratch — full teardown (./cleanup.sh) and restart is the safe
# fallback if state gets too tangled.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="dev"
IMAGE_TAG="v1"
REPO_URL="https://github.com/mridulsingh8390/dotnet8.git"

echo "############################################################"
echo "# STEP 1/5: AWS infrastructure (this takes ~25-35 min, mostly RDS)"
echo "############################################################"
chmod +x ./00-aws-infra.sh
./00-aws-infra.sh

source ./.infra-state.env
echo "Loaded state for cluster=$CLUSTER_NAME, region=$REGION"

echo ""
echo "############################################################"
echo "# PAUSE: create the application database before continuing"
echo "############################################################"
echo "RDS does not support creating a named database via the API for SQL"
echo "Server engines. Connect now and run:"
echo "  CREATE DATABASE $SQL_DB_NAME;"
echo ""
echo "Easiest path: run a temporary pod with sqlcmd once the EKS cluster is"
echo "up (it is, at this point in the script):"
echo "  kubectl run sqlcmd-tmp --rm -it --restart=Never -n default --image=mcr.microsoft.com/mssql-tools -- \\"
echo "    /opt/mssql-tools/bin/sqlcmd -S $SQL_ENDPOINT -U $SQL_ADMIN_USER -P '<password from .infra-state.env is not stored here for safety>' -Q \"CREATE DATABASE $SQL_DB_NAME;\""
echo ""
echo "Get the password with:"
echo "  aws secretsmanager get-secret-value --secret-id $SECRET_NAME --region $REGION --query SecretString --output text | jq -r .password"
echo ""
read -r -p "Press Enter once the database has been created, to continue..." _

echo "############################################################"
echo "# STEP 2/5: IRSA, Secrets Store CSI driver, ALB controller, Calico"
echo "############################################################"
chmod +x ./01-aws-lbc-and-identity.sh
./01-aws-lbc-and-identity.sh

source ./.infra-state.env   # reload - 01-aws-lbc-and-identity.sh appended POD_ROLE_ARN

echo "############################################################"
echo "# STEP 3/5: Filling in placeholders"
echo "############################################################"

substitute() {
  local file="$1"
  sed -i \
    -e "s|<POD-IAM-ROLE-ARN>|${POD_ROLE_ARN}|g" \
    -e "s|<SQL-SECRET-ARN>|${SECRET_ARN}|g" \
    -e "s|<ECR_URI>|${ECR_URI}|g" \
    -e "s|<AWS_REGION>|${REGION}|g" \
    "$file"
  echo "   updated: $file"
}

for f in \
  k8s/dev/01-serviceaccount.yaml \
  k8s/dev/02-secretproviderclass.yaml \
  k8s/dev/04-deployment-service.yaml \
  build-and-push.sh
do
  substitute "$f"
done

echo ""
echo "NOTE: k8s/dev/05-networkpolicy.yaml still has <ALB-SUBNET-CIDRS> as a"
echo "placeholder — this is NOT auto-filled, since the right value depends"
echo "on which subnets the ALB controller actually lands the load balancer"
echo "in, which isn't known until after the Ingress is created in step 5."
echo "The script applies a safe default (full VPC CIDR) below and prints"
echo "instructions to narrow it afterward."
sed -i "s|<ALB-SUBNET-CIDRS>|${VPC_CIDR:-10.20.0.0/16}|g" k8s/dev/05-networkpolicy.yaml

echo "############################################################"
echo "# STEP 4/5: Build and push dotnet image to ECR"
echo "############################################################"

WORKDIR="$(mktemp -d)"
echo "==> Cloning $REPO_URL"
git clone --depth 1 "$REPO_URL" "$WORKDIR/src"

cp app/Dockerfile "$WORKDIR/src/Dockerfile"
cp app/.dockerignore "$WORKDIR/src/.dockerignore"

echo "==> NOTE: verify the csproj/assembly name matches the Dockerfile ENTRYPOINT"
find "$WORKDIR/src" -name "*.csproj" -exec echo "   found csproj: {}" \;

echo "==> Building image"
docker build -t "${ECR_URI}:${IMAGE_TAG}" "$WORKDIR/src"

echo "==> Logging into ECR and pushing"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$(echo "$ECR_URI" | cut -d'/' -f1)"
docker push "${ECR_URI}:${IMAGE_TAG}"

rm -rf "$WORKDIR"

echo "############################################################"
echo "# STEP 5/5: Applying Kubernetes manifests"
echo "############################################################"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

kubectl apply -f k8s/dev/00-namespace.yaml
kubectl apply -f k8s/dev/01-serviceaccount.yaml
kubectl apply -f k8s/dev/02-secretproviderclass.yaml
kubectl apply -f k8s/dev/03-configmap.yaml
kubectl apply -f k8s/dev/04-deployment-service.yaml
kubectl apply -f k8s/dev/05-networkpolicy.yaml
kubectl apply -f k8s/dev/07-ingress-alb.yaml

echo "==> Waiting for deployment rollout"
kubectl rollout status deployment/dotnet-helloworld -n "$NAMESPACE" --timeout=180s || \
  echo "   (rollout didn't complete in time — check 'kubectl get pods -n dev' and 'kubectl describe pod' for details)"

echo "############################################################"
echo "# DONE"
echo "############################################################"
echo "Cluster:              $CLUSTER_NAME"
echo "Region:                $REGION"
echo "ECR image:             ${ECR_URI}:${IMAGE_TAG}"
echo "RDS endpoint:          $SQL_ENDPOINT:$SQL_PORT"
echo "Secrets Manager ARN:   $SECRET_ARN"
echo "Pod IAM role:          $POD_ROLE_ARN"
echo ""
echo "Verify pods:           kubectl get pods -n dev"
echo "Verify env/secrets:    kubectl exec -n dev deploy/dotnet-helloworld -- env | grep SQL_"
echo "Verify ping policy:    kubectl apply -f k8s/dev/06-network-test-pods.yaml"
echo "                       then see README.md for the ping test commands"
echo "Verify ALB:            kubectl get ingress -n dev   (wait a few min for ADDRESS to populate)"
echo "Rotate password:       ./rotate-sql-password.sh"
echo "Tear everything down:  ./cleanup.sh"
echo ""
echo "IMPORTANT: once the ALB has an address, check its actual subnet"
echo "placement (EC2 console -> Load Balancers -> your ALB -> Network map,"
echo "or: aws elbv2 describe-load-balancers --region $REGION) and narrow"
echo "k8s/dev/05-networkpolicy.yaml's ipBlock from the full VPC CIDR down"
echo "to just those subnet CIDRs, then re-apply. The full-VPC-CIDR default"
echo "works but is broader than necessary — same lesson learned debugging"
echo "the AKS lab's equivalent issue, applied proactively here instead."
echo "############################################################"
