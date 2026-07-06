#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-and-push.sh
# Clones the source repo, builds the image with the Dockerfile in ./app,
# and pushes to ECR. Run from the eks-lab/ directory.
# ---------------------------------------------------------------------------
set -euo pipefail

ECR_URI="<ECR_URI>"               # from the infra script output, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/dotnet-helloworld
REGION="<AWS_REGION>"
IMAGE_TAG="v1"
REPO_URL="https://github.com/mridulsingh8390/dotnet8.git"

WORKDIR="$(mktemp -d)"
git clone "$REPO_URL" "$WORKDIR/src"

cp app/Dockerfile "$WORKDIR/src/Dockerfile"
cp app/.dockerignore "$WORKDIR/src/.dockerignore"

echo "==> Building image"
docker build -t "${ECR_URI}:${IMAGE_TAG}" "$WORKDIR/src"

echo "==> Logging into ECR"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$(echo "$ECR_URI" | cut -d'/' -f1)"

echo "==> Pushing image"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo "Image pushed: ${ECR_URI}:${IMAGE_TAG}"
echo "Update the image field in k8s/dev/04-deployment-service.yaml to match, then kubectl apply."

rm -rf "$WORKDIR"
