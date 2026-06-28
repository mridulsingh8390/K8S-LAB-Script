#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 01b-install-efs-csi-driver.sh
# Installs the Amazon EFS CSI driver into the EKS cluster, with IRSA
# granting it the AWS-managed AmazonEFSCSIDriverPolicy, and creates a
# StorageClass for dynamic provisioning against the EFS file system created
# in 00b-aws-efs.sh.
#
# Genuinely simpler than the AKS lab's ANF/Trident equivalent: no
# third-party operator, no separate per-cloud service principal - just
# IRSA (which this whole lab series already uses elsewhere) and the
# official AWS-maintained CSI driver.
#
# Run this AFTER 00b-aws-efs.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source ./.infra-state.env

echo "############################################################"
echo "# 1/3: IRSA for the EFS CSI driver"
echo "############################################################"
eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --region="$REGION" \
  --namespace=kube-system \
  --name=efs-csi-controller-sa \
  --attach-policy-arn=arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
  --override-existing-serviceaccounts \
  --approve

echo "############################################################"
echo "# 2/3: Installing the EFS CSI driver via Helm"
echo "############################################################"
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ >/dev/null
helm repo update >/dev/null

helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=efs-csi-controller-sa

echo "    ...waiting for the controller deployment to roll out"
kubectl rollout status deployment/efs-csi-controller -n kube-system --timeout=120s

echo "############################################################"
echo "# 3/3: StorageClass for dynamic EFS provisioning (access-point based)"
echo "############################################################"
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${EFS_ID}"
  directoryPerms: "700"
  basePath: "/postgres-data"
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

echo "============================================================"
echo "DONE."
echo "  EFS CSI driver:    installed in kube-system"
echo "  StorageClass:      efs-sc (provisioner: efs.csi.aws.com, fileSystemId: ${EFS_ID})"
echo "============================================================"
echo "Next: apply the PostgreSQL manifests in dev-postgres-efs/"
