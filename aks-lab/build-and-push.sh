#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-and-push.sh
# Clones the source repo, builds the image with the Dockerfile in ./app,
# and pushes to ACR. Run from the aks-lab/ directory.
# ---------------------------------------------------------------------------
set -euo pipefail

ACR_NAME="<ACR_NAME>"            # from the infra script output
IMAGE_NAME="dotnet-helloworld"
IMAGE_TAG="v1"
REPO_URL="https://github.com/mridulsingh8390/dotnet8.git"

WORKDIR="$(mktemp -d)"
git clone "$REPO_URL" "$WORKDIR/src"

# Drop in the Dockerfile/.dockerignore we generated alongside the cloned source
cp app/Dockerfile "$WORKDIR/src/Dockerfile"
cp app/.dockerignore "$WORKDIR/src/.dockerignore"

echo "==> Building image"
docker build -t "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}" "$WORKDIR/src"

echo "==> Logging into ACR"
az acr login --name "$ACR_NAME"

echo "==> Pushing image"
docker push "${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"

echo "Image pushed: ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
echo "Update the image field in k8s/dev/04-deployment-service.yaml to match, then kubectl apply."

rm -rf "$WORKDIR"
