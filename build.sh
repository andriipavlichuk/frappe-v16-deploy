#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/config.env"
set +a

log() { echo -e "\033[0;34m$(date +'%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
error_exit() { echo -e "\033[0;31m$(date +'%Y-%m-%d %H:%M:%S') - ERROR $1\033[0m"; exit 1; }

DOCKER_DIR="$SCRIPT_DIR/docker"
CONTAINERFILE="$DOCKER_DIR/Containerfile"
[ -f "$CONTAINERFILE" ] || error_exit "Containerfile not found: $CONTAINERFILE"
[ -f "$APPS_JSON" ] || error_exit "apps.json not found: $APPS_JSON"

APPS_CUSTOM_JSON="${APPS_CUSTOM_JSON:-$SCRIPT_DIR/apps.custom.json}"

export DOCKER_BUILDKIT=1
APPS_JSON_HASH="$(sha256sum "$APPS_JSON" | awk '{print $1}')"

# Bakes frappe + the stable apps listed in apps.json into the image.
# The secret's contents do not affect Docker's cache key. CACHE_BUST is consumed
# by the app-install layer in the Containerfile, so this hash reruns that layer
# whenever apps.json changes without exposing its contents to the build.
SECRET_ARGS=(--secret=id=apps_json,src="$APPS_JSON")

# Fast-moving apps (apps.custom.json) get their own later layer, cache-busted
# off each app's live branch HEAD rather than the json file's contents. This
# way a new commit on e.g. custom apps' branch rebuilds only that small layer,
# without touching apps.custom.json and without invalidating frappe/erpnext.
CACHE_BUST_CUSTOM=""
if [ -f "$APPS_CUSTOM_JSON" ] && [ -s "$APPS_CUSTOM_JSON" ]; then
  SECRET_ARGS+=(--secret=id=apps_custom_json,src="$APPS_CUSTOM_JSON")
  CACHE_BUST_CUSTOM="$(jq -r '.[] | "\(.url) \(.branch // "")"' "$APPS_CUSTOM_JSON" | \
    while read -r url branch; do
      git ls-remote "$url" "${branch:-HEAD}" | awk '{print $1}'
    done | sha256sum | awk '{print $1}')"
  log "Custom apps cache-bust: $CACHE_BUST_CUSTOM (live HEAD of $APPS_CUSTOM_JSON branches)"
fi

log "Building $IMAGE_TAG (frappe $FRAPPE_BRANCH) with apps from $APPS_JSON"
docker build \
  --build-arg=FRAPPE_PATH="$FRAPPE_REPO" \
  --build-arg=FRAPPE_BRANCH="$FRAPPE_BRANCH" \
  --build-arg=PYTHON_VERSION="${PYTHON_VERSION:-3.14.2}" \
  --build-arg=NODE_VERSION="${NODE_VERSION:-24.13.0}" \
  --build-arg=CACHE_BUST="$APPS_JSON_HASH" \
  --build-arg=CACHE_BUST_CUSTOM="$CACHE_BUST_CUSTOM" \
  "${SECRET_ARGS[@]}" \
  -t "$IMAGE_TAG" \
  -f "$CONTAINERFILE" "$DOCKER_DIR" || error_exit "Docker build failed"

printf "\033[0;32mBuilt $IMAGE_TAG\033[0m\n"
