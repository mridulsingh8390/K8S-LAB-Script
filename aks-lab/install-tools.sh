#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-tools.sh
# Installs git, Azure CLI, kubectl, and Docker Engine on Ubuntu/Debian.
# Sourced from the official install methods for each tool (Microsoft Learn
# for az/kubectl, docs.docker.com for Docker Engine) as of June 2026.
#
# Run with sudo privileges available (it calls sudo internally, don't run
# the whole script as root — run it as your normal user).
#
# After this finishes, LOG OUT AND BACK IN (or run `newgrp docker`) before
# using docker without sudo — group membership changes don't apply to the
# current shell session.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "############################################################"
echo "# 1/4: git"
echo "############################################################"
sudo apt-get update
sudo apt-get install -y git
git --version

echo "############################################################"
echo "# 2/4: Azure CLI (az)"
echo "############################################################"
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az --version

echo "############################################################"
echo "# 3/4: kubectl"
echo "############################################################"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl
kubectl version --client

echo "############################################################"
echo "# 4/4: Docker Engine"
echo "############################################################"
# Remove conflicting/unofficial packages if present (safe no-op if absent)
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

# Allow running docker without sudo
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"

docker --version

echo "############################################################"
echo "DONE."
echo "git, az, kubectl, and docker are installed."
echo ""
echo "IMPORTANT: log out and back in (or run: newgrp docker) before"
echo "running 'docker ps' without sudo — group membership only takes"
echo "effect in a fresh shell session."
echo ""
echo "Next steps:"
echo "  az login                     (or: az login --use-device-code)"
echo "  docker ps                    (verify, after re-login)"
echo "  kubectl version --client     (verify)"
echo "############################################################"
