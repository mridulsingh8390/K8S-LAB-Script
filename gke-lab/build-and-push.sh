#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-and-push.sh
# Clones the source repo, builds the image with the Dockerfile in ./app,
# and pushes to Artifact Registry. Run from the gke-lab/ directory.
# ---------------------------------------------------------------------------
set -euo pipefail

AR_URI="<AR_URI>"   # from the infra script output, e.g. us-central1-docker.pkg.dev/my-project/dotnet-helloworld/dotnet-helloworld
REGION="<GCP_REGION>"
IMAGE_TAG="v1"
REPO_URL="https://github.com/mridulsingh8390/dotnet8.git"

WORKDIR="$(mktemp -d)"
git clone "$REPO_URL" "$WORKDIR/src"

cp app/Dockerfile "$WORKDIR/src/Dockerfile"
cp app/.dockerignore "$WORKDIR/src/.dockerignore"

echo "==> Building image"
docker build -t "${AR_URI}:${IMAGE_TAG}" "$WORKDIR/src"

echo "==> Configuring docker auth for Artifact Registry"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "==> Pushing image"
docker push "${AR_URI}:${IMAGE_TAG}"

echo "Image pushed: ${AR_URI}:${IMAGE_TAG}"
echo "Update the image field in k8s/dev/04-deployment-service.yaml to match, then kubectl apply."

rm -rf "$WORKDIR"
