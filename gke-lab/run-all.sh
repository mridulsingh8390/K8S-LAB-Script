#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-all.sh
# End-to-end orchestrator for the GKE lab - same role as the AKS/EKS labs'
# run-all.sh. Run this ONE script from the gke-lab/ directory and it will:
#   1. Run 00-gcp-infra.sh (VPC/GKE/Artifact Registry/Cloud SQL/Secret Manager)
#   2. Run 01-gke-identity-and-sql.sh (Workload Identity, CSI driver)
#   3. Substitute every <PLACEHOLDER> in the k8s YAML and helper scripts
#   4. Build and push the dotnet image to Artifact Registry
#   5. kubectl apply everything in the correct order
#   6. Print a summary + the verification commands to run
#
# Run it as:  ./run-all.sh
#
# NOTE: GKE Ingress and NetworkPolicy enforcement need NO separate install
# step here, unlike the AKS lab (AGIC) and the EKS lab (AWS Load Balancer
# Controller, Calico/VPC-CNI-native-mode). The GCE Ingress Controller is
# built into GKE; NetworkPolicy enforcement is built into Dataplane V2,
# enabled at cluster creation in 00-gcp-infra.sh. This is structurally why
# the GKE lab does not carry the same "enabling this on a live cluster"
# risk that caused a real, documented incident on the EKS lab.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="dev"
IMAGE_TAG="v1"
REPO_URL="https://github.com/mridulsingh8390/dotnet8.git"

echo "############################################################"
echo "# STEP 1/5: GCP infrastructure (this takes ~15-25 min, mostly Cloud SQL)"
echo "############################################################"
chmod +x ./00-gcp-infra.sh
./00-gcp-infra.sh

source ./.infra-state.env
echo "Loaded state for project=$PROJECT_ID, cluster=$CLUSTER_NAME"

echo "############################################################"
echo "# STEP 2/5: Workload Identity, Secrets Store CSI driver"
echo "############################################################"
chmod +x ./01-gke-identity-and-sql.sh
./01-gke-identity-and-sql.sh

source ./.infra-state.env   # reload - 01-gke-identity-and-sql.sh appended GSA_EMAIL

echo "############################################################"
echo "# STEP 3/5: Filling in placeholders"
echo "############################################################"

substitute() {
  local file="$1"
  sed -i \
    -e "s|<GSA-EMAIL>|${GSA_EMAIL}|g" \
    -e "s|<PROJECT_ID>|${PROJECT_ID}|g" \
    -e "s|<AR_URI>|${AR_URI}|g" \
    -e "s|<GCP_REGION>|${REGION}|g" \
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

echo "############################################################"
echo "# STEP 4/5: Build and push dotnet image to Artifact Registry"
echo "############################################################"

WORKDIR="$(mktemp -d)"
echo "==> Cloning $REPO_URL"
git clone --depth 1 "$REPO_URL" "$WORKDIR/src"

cp app/Dockerfile "$WORKDIR/src/Dockerfile"
cp app/.dockerignore "$WORKDIR/src/.dockerignore"

echo "==> NOTE: verify the csproj/assembly name matches the Dockerfile ENTRYPOINT"
find "$WORKDIR/src" -name "*.csproj" -exec echo "   found csproj: {}" \;

echo "==> Building image"
docker build -t "${AR_URI}:${IMAGE_TAG}" "$WORKDIR/src"

echo "==> Configuring docker auth for Artifact Registry and pushing"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker push "${AR_URI}:${IMAGE_TAG}"

rm -rf "$WORKDIR"

echo "############################################################"
echo "# STEP 5/5: Applying Kubernetes manifests"
echo "############################################################"

gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID"

kubectl apply -f k8s/dev/00-namespace.yaml
kubectl apply -f k8s/dev/01-serviceaccount.yaml
kubectl apply -f k8s/dev/02-secretproviderclass.yaml
kubectl apply -f k8s/dev/03-configmap.yaml
kubectl apply -f k8s/dev/04-deployment-service.yaml
kubectl apply -f k8s/dev/05-networkpolicy.yaml
kubectl apply -f k8s/dev/07-ingress-gke.yaml

echo "==> Waiting for deployment rollout"
kubectl rollout status deployment/dotnet-helloworld -n "$NAMESPACE" --timeout=180s || \
  echo "   (rollout didn't complete in time - check 'kubectl get pods -n dev' and 'kubectl describe pod' for details)"

echo "############################################################"
echo "# DONE"
echo "############################################################"
echo "Project:               $PROJECT_ID"
echo "Cluster:               $CLUSTER_NAME"
echo "Artifact Registry:     ${AR_URI}:${IMAGE_TAG}"
echo "Cloud SQL private IP:  $SQL_PRIVATE_IP"
echo "GSA email:             $GSA_EMAIL"
echo ""
echo "Verify pods:           kubectl get pods -n dev"
echo "Verify env/secrets:    kubectl exec -n dev deploy/dotnet-helloworld -- env | grep SQL_"
echo "Verify ping policy:    kubectl apply -f k8s/dev/06-network-test-pods.yaml"
echo "                       then see README.md for the ping test commands"
echo "Verify GKE Ingress:    kubectl get ingress -n dev   (can take 5-10 min for ADDRESS to populate - GKE Ingress is slower to provision than AGIC/ALB)"
echo "Rotate password:       ./rotate-sql-password.sh"
echo "Tear everything down:  ./cleanup.sh"
echo "############################################################"
