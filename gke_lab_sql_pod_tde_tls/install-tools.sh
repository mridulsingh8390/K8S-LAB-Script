#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-tools.sh
# Installs git, jq, the Google Cloud CLI (gcloud), kubectl, helm, and
# Docker Engine on Ubuntu/Debian - the GKE-lab equivalent of the AKS/EKS
# labs' install-tools.sh.
#
# Run as your normal user (it calls sudo internally).
#
# After this finishes, LOG OUT AND BACK IN (or run: newgrp docker) before
# using docker without sudo.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "############################################################"
echo "# 1/5: git, jq"
echo "############################################################"
sudo apt-get update
sudo apt-get install -y git jq apt-transport-https ca-certificates gnupg curl
git --version
jq --version

echo "############################################################"
echo "# 2/5: Google Cloud CLI (gcloud)"
echo "############################################################"
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
  sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
sudo apt-get update
sudo apt-get install -y google-cloud-cli
gcloud --version

echo "############################################################"
echo "# 3/5: kubectl (via the gcloud-managed apt component)"
echo "############################################################"
sudo apt-get install -y kubectl google-cloud-cli-gke-gcloud-auth-plugin
kubectl version --client
# The gke-gcloud-auth-plugin is required for kubectl to authenticate against
# GKE clusters on current gcloud/kubectl versions - without it,
# `gcloud container clusters get-credentials` will configure a kubeconfig
# entry that fails to authenticate.
echo 'export USE_GKE_GCLOUD_AUTH_PLUGIN=True' >> "$HOME/.bashrc"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

echo "############################################################"
echo "# 4/5: Helm"
echo "############################################################"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x /tmp/get_helm.sh
/tmp/get_helm.sh
rm -f /tmp/get_helm.sh
helm version

echo "############################################################"
echo "# 5/5: Docker Engine"
echo "############################################################"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done

sudo apt-get update
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
echo "git, jq, gcloud, kubectl, helm, and docker are installed."
echo ""
echo "IMPORTANT: log out and back in (or run: newgrp docker AND"
echo "source ~/.bashrc) before running 'docker ps' without sudo, and"
echo "to pick up the USE_GKE_GCLOUD_AUTH_PLUGIN environment variable."
echo ""
echo "Next steps:"
echo "  gcloud auth login                  (or: gcloud auth login --no-launch-browser on headless machines)"
echo "  gcloud config set project <id>     (set your GCP project)"
echo "  docker ps                          (verify, after re-login)"
echo "  kubectl version --client           (verify)"
echo "############################################################"
