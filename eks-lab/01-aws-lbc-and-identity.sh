#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-aws-lbc-and-identity.sh
# Sets up everything AKS gave us "for free" via single addon flags, but
# which EKS requires assembling by hand:
#   - IAM role for the app pod (IRSA) to read the Secrets Manager secret
#   - Secrets Store CSI driver + the AWS provider for it (the AWS analog
#     to AKS's azure-keyvault-secrets-provider addon)
#   - AWS Load Balancer Controller (the AWS analog to AGIC)
#   - Calico in policy-only mode on top of the VPC CNI (the AWS analog to
#     AKS's --network-policy azure flag) — this one genuinely is more
#     involved on EKS than AKS; there is no single "enable network policy"
#     addon flag for Calico specifically (AWS's own VPC CNI has a native
#     NetworkPolicy mode as an alternative — see the comment further down
#     if you'd rather use that rate than full Calico).
#
# Run this AFTER 00-aws-infra.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./.infra-state.env

POD_IDENTITY_NAME="eks-lab-dotnet-app-role"
SA_NAME="dotnet-app-sa"
NAMESPACE="dev"

echo "############################################################"
echo "# 1/4: IRSA — IAM role for the pod's ServiceAccount to read Secrets Manager"
echo "############################################################"

OIDC_PROVIDER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text | sed -e 's|^https://||')

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

aws iam create-role \
  --role-name "$POD_IDENTITY_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" >/dev/null 2>&1 || \
  echo "   (role already exists, continuing)"

SECRETS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": "${SECRET_ARN}"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$POD_IDENTITY_NAME" \
  --policy-name "eks-lab-secrets-read" \
  --policy-document "$SECRETS_POLICY"

POD_ROLE_ARN=$(aws iam get-role --role-name "$POD_IDENTITY_NAME" --query "Role.Arn" --output text)
echo "Pod IAM role ARN: $POD_ROLE_ARN"

echo "############################################################"
echo "# 2/4: Secrets Store CSI Driver + AWS provider"
echo "############################################################"
# Same role as AKS's azure-keyvault-secrets-provider addon, but on EKS this
# is a Helm chart install rather than a single `az aks enable-addons` flag.
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts >/dev/null
helm repo update >/dev/null

helm upgrade --install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true

# The AWS provider for the CSI driver (lets it actually talk to Secrets Manager)
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

echo "############################################################"
echo "# 3/4: AWS Load Balancer Controller (ALB Ingress — the AGIC equivalent)"
echo "############################################################"
curl -sL -o /tmp/iam-policy-lbc.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/iam-policy-lbc.json >/dev/null 2>&1 || \
  echo "   (IAM policy already exists, continuing)"

eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --region="$REGION" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID"

echo "    ...waiting for the controller deployment to roll out"
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

echo "############################################################"
echo "# 4/4: Calico (policy-only mode on top of VPC CNI) for NetworkPolicy enforcement"
echo "############################################################"
# This is the more involved AWS equivalent of AKS's --network-policy azure
# flag. AWS VPC CNI's OWN native NetworkPolicy mode (enableNetworkPolicy on
# the vpc-cni addon) is a simpler, AWS-native alternative if you'd rather
# not run Calico at all — see the commented block below. Since Calico was
# the explicit choice for this lab, we install the Tigera operator and
# configure Calico in policy-only mode (Calico does NOT replace VPC CNI's
# networking/IPAM here, only adds policy enforcement on top of it).
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=180s

cat <<'EOF' | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  kubernetesProvider: EKS
  cni:
    type: AmazonVPC
  calicoNetwork: null
EOF

echo "    ...waiting for Calico to report ready (can take a few minutes)"
sleep 30
kubectl get pods -n calico-system

# Annotate aws-node so pod IPs propagate to Calico promptly (documented
# requirement for VPC-CNI + Calico policy-only mode)
kubectl set env -n kube-system daemonset/aws-node ANNOTATE_POD_IP=true

# ---------------------------------------------------------------------------
# ALTERNATIVE (not used here, since Calico was the explicit choice): AWS
# VPC CNI's own native NetworkPolicy support needs no separate install —
# just enable it on the vpc-cni addon itself:
#   eksctl utils update-cluster-vpc-cni-addon --cluster $CLUSTER_NAME \
#     --region $REGION --enable-network-policy
# If you ever want to switch, uninstall Calico first
# (kubectl delete -f the same manifests above) to avoid both controllers
# fighting over the same NetworkPolicy objects.
# ---------------------------------------------------------------------------

echo "============================================================"
echo "DONE."
echo "  Pod IAM role ARN:            $POD_ROLE_ARN"
echo "  AWS Load Balancer Controller: installed in kube-system"
echo "  Calico:                       installed in calico-system (policy-only mode)"
echo "============================================================"
echo "Update the placeholder in k8s/dev/01-serviceaccount.yaml with:"
echo "  $POD_ROLE_ARN"
echo "(run-all.sh does this substitution automatically if you use that instead)"

cat >> .infra-state.env <<EOF
POD_ROLE_ARN="$POD_ROLE_ARN"
EOF
