#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/config.env"
set +a

log() { echo -e "\033[0;34m$(date +'%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
error_exit() { echo -e "\033[0;31m$(date +'%Y-%m-%d %H:%M:%S') - ERROR $1\033[0m"; exit 1; }
warn() { echo -e "\033[0;33m$(date +'%Y-%m-%d %H:%M:%S') - WARNING $1\033[0m"; }

FD="$SCRIPT_DIR/docker"
cd "$FD" || error_exit "Cannot cd to $FD"

mkdir -p "$GITOPS_PATH"
ENVFILE="$GITOPS_PATH/$PROJECT_NAME.env"

# IMAGE_TAG (compose.yaml) and PROJECT_NAME (overrides/compose.mariadb-shared.yaml)
# are consumed via ${VAR} interpolation, exported above from config.env - no more
# in-place sed patching of these vendored files.

# --- erpnext env file ---
cp example.env "$ENVFILE"
sed -i "s/^DB_PASSWORD=123/DB_PASSWORD=$DB_PASSWORD/" "$ENVFILE"
sed -i "s/^DB_HOST=/DB_HOST=mariadb-$PROJECT_NAME/" "$ENVFILE"
sed -i "s/^DB_PORT=/DB_PORT=3306/" "$ENVFILE"
sed -i "s/SITES=\`erp.example.com\`/SITES=\`$SITE_NAME\`/" "$ENVFILE"
echo "ROUTER=erpnext-$PROJECT_NAME" >> "$ENVFILE"
echo "BENCH_NETWORK=erpnext-$PROJECT_NAME" >> "$ENVFILE"
echo "FRAPPE_SITE_NAME_HEADER=$SITE_NAME" >> "$ENVFILE"

# --- overrides selection ---
OVERRIDES="-f overrides/compose.redis.yaml -f overrides/compose.multi-bench.yaml"
if [ "$MODE" = "http" ]; then
  log "MODE=http: publishing frontend on port $HTTP_PORT (no Traefik)"
  cat > "$GITOPS_PATH/compose.local-http.yaml" <<EOF
services:
  frontend:
    ports:
      - "${HTTP_PORT}:8080"
EOF
  docker network create traefik-public 2>/dev/null || true
  OVERRIDES="$OVERRIDES -f $GITOPS_PATH/compose.local-http.yaml"
elif [ "$MODE" = "traefik" ]; then
  log "MODE=traefik: starting Traefik for $DOMAIN"
  docker compose --project-name traefik --env-file "$GITOPS_PATH/traefik.env" \
    -f overrides/compose.traefik.yaml -f overrides/compose.traefik-ssl.yaml up -d
  echo "SITES_RULE=Host(\`$DOMAIN\`)" >> "$ENVFILE"
  OVERRIDES="$OVERRIDES -f overrides/compose.multi-bench-ssl.yaml"
else
  error_exit "Unknown MODE=$MODE (use http or traefik)"
fi

# --- render final compose ---
docker compose --project-name "erpnext-$PROJECT_NAME" --env-file "$ENVFILE" \
  -f compose.yaml $OVERRIDES config > "$GITOPS_PATH/$PROJECT_NAME.yaml" \
  || error_exit "Failed to render compose"

# --- ensure custom image exists ---
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  log "Image $IMAGE_TAG not found locally. Building now..."
  ( cd "$SCRIPT_DIR" && bash build.sh ) || error_exit "Build failed"
else
  log "Using existing image: $IMAGE_TAG"
fi

# --- mariadb ---
echo "DB_PASSWORD=$DB_PASSWORD" > "$GITOPS_PATH/mariadb.env"
docker compose --project-name "mariadb-$PROJECT_NAME" --env-file "$GITOPS_PATH/mariadb.env" \
  -f overrides/compose.mariadb-shared.yaml up -d || error_exit "Failed to start MariaDB"

# --- erpnext stack ---
docker compose --project-name "erpnext-$PROJECT_NAME" -f "$GITOPS_PATH/$PROJECT_NAME.yaml" up -d \
  || error_exit "Failed to start ERPNext"

# --- ensure build tools in backend (needed for native deps) ---
log "Ensuring gcc/g++ in backend container for native builds"
docker compose --project-name "erpnext-$PROJECT_NAME" exec -u root backend \
  bash -c "apt-get update >/dev/null 2>&1 && apt-get install -y gcc g++ >/dev/null 2>&1" \
  || warn "Could not install gcc in backend (native builds may fail)"

# --- create site if it does not exist ---
if ! docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
  bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
  log "Creating fresh site $SITE_NAME"
  docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
    bench new-site "$SITE_NAME" --mariadb-user-host-login-scope='%' \
    --mariadb-root-password "$DB_PASSWORD" --install-app erpnext \
    --admin-password "$ADMIN_PASSWORD" || error_exit "Failed to create site"
fi

# --- install every baked app not yet installed on the site ---
# Runs on every deploy, not just when the site is first created: this way a
# single app's install failure (or an app added to apps.json/apps.custom.json
# after the site already existed) is retried/picked up on the next deploy.sh
# run instead of being silently skipped forever once list-apps succeeds.
BAKED_APPS="$(docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
  bash -c 'find /home/frappe/frappe-bench/apps -mindepth 1 -maxdepth 1 -type d -printf "%f\\n"' \
  | sort)" || error_exit "Could not list applications baked into the image"

INSTALLED_APPS="$(docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
  bench --site "$SITE_NAME" list-apps | awk '{print $1}')" \
  || error_exit "Could not list applications installed on $SITE_NAME"

PENDING=()
while IFS= read -r app; do
  case "$app" in
    ""|frappe|erpnext) continue ;;
  esac
  grep -qx "$app" <<< "$INSTALLED_APPS" || PENDING+=("$app")
done <<< "$BAKED_APPS"

# Multi-pass: some baked apps declare required_apps on other baked apps (e.g.
# lms requires payments), so a single alphabetical pass can fail purely on
# install order. Retry whatever is still pending each pass until a full pass
# installs nothing new, which means the rest are genuine failures.
while [ "${#PENDING[@]}" -gt 0 ]; do
  NEXT_PENDING=()
  INSTALLED_THIS_PASS=0
  for app in "${PENDING[@]}"; do
    log "Installing $app on $SITE_NAME"
    if docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
      bench --site "$SITE_NAME" install-app "$app"; then
      INSTALLED_THIS_PASS=1
    else
      NEXT_PENDING+=("$app")
    fi
  done
  if [ "$INSTALLED_THIS_PASS" -eq 0 ]; then
    error_exit "Failed to install: ${NEXT_PENDING[*]} (not a dependency-order issue; check the install-app output above)"
  fi
  PENDING=("${NEXT_PENDING[@]}")
done

log "Migrating $SITE_NAME"
docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
  bench --site "$SITE_NAME" migrate || error_exit "Migration failed"

# Restart the long-running workers so they pick up newly installed apps
# (gunicorn/websocket started before get-app, so their sys.path is stale).
log "Restarting workers to load installed apps"
docker compose --project-name "erpnext-$PROJECT_NAME" restart backend websocket frontend \
  || warn "Worker restart failed; restart the stack manually if apps 404/500"

printf "\033[0;32m%s is deployed (MODE=%s)\033[0m\n" "$SITE_NAME" "$MODE"
if [ "$MODE" = "http" ]; then
  echo "Open: http://localhost:$HTTP_PORT/"
fi
