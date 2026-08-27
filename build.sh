#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

log() { echo -e "\033[0;34m$(date +'%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
error_exit() { echo -e "\033[0;31m$(date +'%Y-%m-%d %H:%M:%S') - ERROR $1\033[0m"; exit 1; }

cd "$FRAPPE_DOCKER_PATH" || error_exit "Cannot cd to $FRAPPE_DOCKER_PATH"
[ -f "$APPS_JSON" ] || error_exit "apps.json not found: $APPS_JSON"

export DOCKER_BUILDKIT=1

# Bakes frappe + the apps listed in apps.json into the image.
# (The Containerfile reads apps.json via a BuildKit secret, not a build-arg.)
log "Building $IMAGE_TAG (frappe $FRAPPE_BRANCH) with apps from $APPS_JSON"
docker build \
  --build-arg=FRAPPE_PATH="$FRAPPE_REPO" \
  --build-arg=FRAPPE_BRANCH="$FRAPPE_BRANCH" \
  --build-arg=PYTHON_VERSION="${PYTHON_VERSION:-3.14.2}" \
  --build-arg=NODE_VERSION="${NODE_VERSION:-24.13.0}" \
  --secret=id=apps_json,src="$APPS_JSON" \
  -t "$IMAGE_TAG" \
  -f images/custom/Containerfile . || error_exit "Docker build failed"

printf "\033[0;32mBuilt $IMAGE_TAG\033[0m\n"
