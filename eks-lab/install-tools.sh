#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-tools.sh
# Installs git, AWS CLI v2, eksctl, kubectl, helm, jq, and Docker Engine on
# Ubuntu/Debian — the EKS-lab equivalent of the AKS lab's install-tools.sh.
# Different toolchain since EKS workflows lean on eksctl + helm rather than
# a single `az` CLI doing everything.
#
# Run as your normal user (it calls sudo internally).
#
# After this finishes, LOG OUT AND BACK IN (or run: newgrp docker) before
# using docker without sudo.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "############################################################"
echo "# 1/6: git, unzip, jq"
echo "############################################################"
sudo apt-get update
sudo apt-get install -y git unzip jq
git --version
jq --version

echo "############################################################"
echo "# 2/6: AWS CLI v2"
echo "############################################################"
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws
aws --version

echo "############################################################"
echo "# 3/6: eksctl"
echo "############################################################"
ARCH=$(uname -m)
PLATFORM="Linux_${ARCH}"
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" | sudo tar xz -C /usr/local/bin
eksctl version

echo "############################################################"
echo "# 4/6: kubectl"
echo "############################################################"
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl
kubectl version --client

echo "############################################################"
echo "# 5/6: Helm"
echo "############################################################"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x /tmp/get_helm.sh
/tmp/get_helm.sh
rm -f /tmp/get_helm.sh
helm version

echo "############################################################"
echo "# 6/6: Docker Engine"
echo "############################################################"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"

docker --version

echo "############################################################"
echo "DONE."
echo "git, jq, aws-cli, eksctl, kubectl, helm, and docker are installed."
echo ""
echo "IMPORTANT: log out and back in (or run: newgrp docker) before"
echo "running 'docker ps' without sudo."
echo ""
echo "Next steps:"
echo "  aws configure                 (set access key, secret key, region)"
echo "  aws sts get-caller-identity   (verify)"
echo "  docker ps                     (verify, after re-login)"
echo "  eksctl version                (verify)"
echo "############################################################"
