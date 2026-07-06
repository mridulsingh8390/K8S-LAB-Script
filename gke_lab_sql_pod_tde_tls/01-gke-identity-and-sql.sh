#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-gke-identity-and-sql.sh
# Sets up what AKS/EKS needed a separate install phase for:
#   - A GCP IAM service account (GSA) the pod's Kubernetes ServiceAccount
#     (KSA) can impersonate via Workload Identity Federation, to read the
#     Secret Manager secret
#   - The Secrets Store CSI driver + GCP provider plugin
#
# GKE Ingress (the AGIC/ALB equivalent) needs NO separate controller
# install on GKE - the GCE Ingress Controller is built into GKE itself and
# activates automatically the moment you apply an Ingress object with the
# right class, which is why there's no "install the ingress controller"
# step in this script the way there was for AGIC/the AWS Load Balancer
# Controller. See k8s/dev/07-ingress-gke.yaml.
#
# NetworkPolicy enforcement also needs no separate step here: Dataplane V2,
# enabled at cluster creation in 00-gcp-infra.sh, has it built in already.
#
# Run this AFTER 00-gcp-infra.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./.infra-state.env

GSA_NAME="gke-lab-dotnet-app-gsa"
KSA_NAME="dotnet-app-sa"
NAMESPACE="dev"

echo "############################################################"
echo "# 1/2: Workload Identity Federation - GSA for the pod to impersonate"
echo "############################################################"

GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$GSA_NAME" \
  --project "$PROJECT_ID" \
  --display-name="GKE lab dotnet app workload identity" 2>/dev/null || \
  echo "   (GSA already exists, continuing)"

echo "==> Granting the GSA access to read all 5 SQL Secret Manager secrets"
IFS=',' read -ra SECRET_ID_ARRAY <<< "$SQL_SECRET_IDS"
for secret_id in "${SECRET_ID_ARRAY[@]}"; do
  gcloud secrets add-iam-policy-binding "$secret_id" \
    --project "$PROJECT_ID" \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" >/dev/null
done

echo "==> Allowing the Kubernetes ServiceAccount to impersonate the GSA"
# IAM propagation can take a couple of minutes; this binding is what lets
# system:serviceaccount:dev:dotnet-app-sa authenticate as the GSA.
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
  --project "$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]"

echo "GSA email: $GSA_EMAIL"
echo "    ...waiting briefly for IAM bindings to propagate"
sleep 30

echo "############################################################"
echo "# 2/2: Secrets Store CSI Driver + GCP provider plugin"
echo "############################################################"
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts >/dev/null
helm repo update >/dev/null

helm upgrade --install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true

kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml

echo "    ...waiting for the GCP provider plugin DaemonSet to roll out"
kubectl rollout status daemonset/csi-secrets-store-provider-gcp -n kube-system --timeout=120s

echo "============================================================"
echo "DONE."
echo "  GSA email:                    $GSA_EMAIL"
echo "  Secrets Store CSI driver:     installed in kube-system"
echo "  GCP provider plugin:          installed in kube-system"
echo "  GKE Ingress (GCE Ingress):    no install needed, built into GKE"
echo "  NetworkPolicy enforcement:    built into Dataplane V2, no install needed"
echo "============================================================"
echo "Update the placeholder in k8s/dev/01-serviceaccount.yaml with:"
echo "  $GSA_EMAIL"
echo "(run-all.sh does this substitution automatically if you use that instead)"

cat >> .infra-state.env <<EOF
GSA_EMAIL="$GSA_EMAIL"
EOF
