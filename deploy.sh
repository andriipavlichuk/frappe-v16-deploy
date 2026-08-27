#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

log() { echo -e "\033[0;34m$(date +'%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
error_exit() { echo -e "\033[0;31m$(date +'%Y-%m-%d %H:%M:%S') - ERROR $1\033[0m"; exit 1; }
warn() { echo -e "\033[0;33m$(date +'%Y-%m-%d %H:%M:%S') - WARNING $1\033[0m"; }

FD="$FRAPPE_DOCKER_PATH"
cd "$FD" || error_exit "Cannot cd to $FRAPPE_DOCKER_PATH"

mkdir -p "$GITOPS_PATH"
ENVFILE="$GITOPS_PATH/$PROJECT_NAME.env"

# --- image tag + pull_policy in compose.yaml ---
sed -i "s|.*  image:.*|  image: $IMAGE_TAG|g" compose.yaml
sed -i "/pull_policy/d" compose.yaml

# --- mariadb container name ---
sed -i "s/container_name: mariadb-database/container_name: mariadb-$PROJECT_NAME/g" overrides/compose.mariadb-shared.yaml

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
  cat > overrides/compose.local-http.yaml <<EOF
services:
  frontend:
    ports:
      - "${HTTP_PORT}:8080"
EOF
  docker network create traefik-public 2>/dev/null || true
  OVERRIDES="$OVERRIDES -f overrides/compose.local-http.yaml"
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

# --- build image if requested (custom-image mode) ---
if [ "${BUILD_MODE:-official}" = "build" ]; then
  if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    log "BUILD_MODE=build: image $IMAGE_TAG already present, skipping build"
  else
    log "BUILD_MODE=build: building image first (run 'bash build.sh' to do this explicitly)"
    ( cd "$SCRIPT_DIR" && bash build.sh ) || error_exit "Build failed"
  fi
fi

# --- mariadb ---
echo "DB_PASSWORD=$DB_PASSWORD" > "$GITOPS_PATH/mariadb.env"
docker compose --project-name "mariadb-$PROJECT_NAME" --env-file "$GITOPS_PATH/mariadb.env" \
  -f overrides/compose.mariadb-shared.yaml up -d || error_exit "Failed to start MariaDB"

# --- erpnext stack ---
docker compose --project-name "erpnext-$PROJECT_NAME" -f "$GITOPS_PATH/$PROJECT_NAME.yaml" up -d \
  || error_exit "Failed to start ERPNext"

# --- ensure build tools in backend (needed to compile native deps like blurhash-python for raven) ---
log "Ensuring gcc/g++ in backend container"
docker compose --project-name "erpnext-$PROJECT_NAME" exec -u root backend \
  bash -c "apt-get update >/dev/null 2>&1 && apt-get install -y gcc g++ >/dev/null 2>&1" \
  || warn "Could not install gcc in backend (native builds may fail)"

# --- install extra apps (official mode) ---
if [ "${BUILD_MODE:-official}" = "official" ]; then
  for entry in $EXTRA_APPS; do
    name="${entry%%|*}"; rest="${entry#*|}"
    url="${rest%%|*}"; branch="${rest#*|}"
    if docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
      test -d "/home/frappe/frappe-bench/apps/$name"; then
      log "App $name already in bench, skipping get-app"
    else
      log "Installing app $name ($url @ $branch)"
      docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
        bench get-app "$url" --branch "$branch" || error_exit "Failed to get-app $name"
    fi
  done
fi

# --- create site if it does not exist (fresh test only; skip when migrating) ---
if ! docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
  bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
  log "Creating fresh site $SITE_NAME"
  docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
    bench new-site "$SITE_NAME" --mariadb-user-host-login-scope='%' \
    --mariadb-root-password "$DB_PASSWORD" --install-app erpnext \
    --admin-password "$ADMIN_PASSWORD" || error_exit "Failed to create site"
  for entry in $EXTRA_APPS; do
    name="${entry%%|*}"
    docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
      bench --site "$SITE_NAME" install-app "$name" || error_exit "Failed to install-app $name"
  done
fi

log "Migrating $SITE_NAME"
docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
  bench --site "$SITE_NAME" migrate || error_exit "Migration failed"

# Restart the long-running workers so they pick up newly installed apps
# (gunicorn/websocket started before get-app, so their sys.path is stale).
log "Restarting workers to load installed apps"
docker compose --project-name "erpnext-$PROJECT_NAME" restart backend websocket frontend \
  || warn "Worker restart failed; restart the stack manually if apps 404/500"

printf "\033[0;32m%s is deployed (MODE=%s, BUILD_MODE=%s)\033[0m\n" "$SITE_NAME" "$MODE" "$BUILD_MODE"
if [ "$MODE" = "http" ]; then
  echo "Open: http://localhost:$HTTP_PORT/"
fi
