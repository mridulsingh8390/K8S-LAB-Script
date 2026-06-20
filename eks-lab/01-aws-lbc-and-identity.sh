#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01-aws-lbc-and-identity.sh
# Sets up everything AKS gave us "for free" via single addon flags, but
# which EKS requires assembling by hand:
#   - IAM role for the app pod (IRSA) to read the Secrets Manager secret
#   - Secrets Store CSI driver + the AWS provider for it (the AWS analog
#     to AKS's azure-keyvault-secrets-provider addon)
#   - AWS Load Balancer Controller (the AWS analog to AGIC)
#   - NetworkPolicy enforcement via VPC CNI's native mode (the AWS analog
#     to AKS's --network-policy azure flag). This was originally Calico
#     (Tigera operator, policy-only mode) but that caused severe,
#     reproducible cluster-wide breakage during real testing — see the
#     detailed warning in Step 4/4 below before considering switching back.
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
  --set enableSecretRotation=true \
  --set 'tokenRequests[0].audience=sts.amazonaws.com'
# tokenRequests is REQUIRED for the AWS provider to authenticate via IRSA —
# without it, the CSIDriver object has no tokenRequests configured, and
# every pod mount fails with:
#   "CSI token error: serviceAccount.tokens not provided - ensure
#    tokenRequests is configured in CSIDriver"
# This is documented directly in the AWS provider's own README but is NOT
# the chart's default — confirmed the hard way during testing (pods stuck
# in ContainerCreating indefinitely until this flag was added and the
# pods were deleted to force a remount attempt).

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
echo "# 4/4: NetworkPolicy enforcement — VPC CNI native mode, opt-in"
echo "############################################################"
# ---------------------------------------------------------------------------
# UPDATED AFTER FURTHER TESTING — read this before deciding whether to
# enable this step.
#
# Earlier testing found that BOTH Calico and VPC CNI's native
# NetworkPolicy mode caused severe, reproducible cluster-wide outages
# (pod-to-pod connectivity loss, CoreDNS unable to reach the API server)
# on this account/cluster. That finding led this script to disable
# NetworkPolicy enforcement entirely by default.
#
# A later retest, performed AFTER fully replacing both EC2 nodes (via
# termination + ASG replacement) so the cluster was in a known-clean
# state, enabled VPC CNI's native mode again and applied the actual
# NetworkPolicy object. This time it worked correctly: DNS and pod health
# remained stable through the whole process, and the dev-only ping
# restriction was confirmed working in both directions (intra-namespace
# allowed, cross-namespace blocked, 100% packet loss).
#
# What this does and does NOT prove: it confirms the feature CAN work
# correctly on this cluster type, and that a clean node state at the time
# of enabling appears to matter. It does NOT prove the earlier failure
# mode is fixed or fully understood — the original root cause was never
# conclusively identified, and we don't know for certain whether the fix
# was "fresh nodes," "this particular sequence of changes," or something
# else entirely that happened to align with the retest. Treat this as
# "worked cleanly on a retest with fresh nodes," not "definitively safe."
#
# THEREFORE: this step remains commented out / opt-in rather than
# automatic in run-all.sh. If you choose to enable it, do so on a cluster
# you've recently refreshed (fresh nodes, like the retest), and verify
# immediately afterward with the same checks used in both the original
# incident and the successful retest:
#   kubectl run dnstest --rm -it --restart=Never --image=busybox -- \
#     nslookup kubernetes.default.svc.cluster.local
#   kubectl get pods -A | grep -v Running
# If either shows a problem, revert immediately (see OPTION 1 command
# below) rather than continuing to investigate live — that was the
# costly mistake during the original incident.
# ---------------------------------------------------------------------------

echo "NetworkPolicy enforcement NOT enabled automatically by this script."
echo "See the comment block above for the retest findings and the exact"
echo "commands to enable it yourself if you choose to, plus the immediate"
echo "verification steps to run right after."

echo "============================================================"
echo "DONE."
echo "  Pod IAM role ARN:            $POD_ROLE_ARN"
echo "  AWS Load Balancer Controller: installed in kube-system"
echo "  NetworkPolicy enforcement:    NOT enabled by default (worked cleanly"
echo "                                 on a retest with fresh nodes - see the"
echo "                                 comment block above before enabling)"
echo "============================================================"
echo "Update the placeholder in k8s/dev/01-serviceaccount.yaml with:"
echo "  $POD_ROLE_ARN"
echo "(run-all.sh does this substitution automatically if you use that instead)"

cat >> .infra-state.env <<EOF
POD_ROLE_ARN="$POD_ROLE_ARN"
EOF
