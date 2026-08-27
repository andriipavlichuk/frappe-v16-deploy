#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"

log() { echo -e "\033[0;34m$(date +'%Y-%m-%d %H:%M:%S') - $1\033[0m"; }
error_exit() { echo -e "\033[0;31m$(date +'%Y-%m-%d %H:%M:%S') - ERROR $1\033[0m"; exit 1; }

if [ $# -lt 1 ]; then
  echo "Usage: $0 /path/to/<timestamp>_database.sql.gz [optional /path/to/<timestamp>_files.tar]"
  echo "The backup must come from the CURRENT v15 site (bench backup on the old server)."
  exit 1
fi

SQL_BACKUP="$1"
FILES_BACKUP="${2:-}"

cd "$FRAPPE_DOCKER_PATH" || error_exit "Cannot cd to $FRAPPE_DOCKER_PATH"

# Copy backup(s) into the backend container's site backup directory
SITE_BACKUP_DIR="/home/frappe/frappe-bench/sites/$SITE_NAME/private/backups"
docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
  mkdir -p "$SITE_BACKUP_DIR" || error_exit "Cannot create backup dir in container"

log "Copying database backup into container"
docker compose --project-name "erpnext-$PROJECT_NAME" cp "$SQL_BACKUP" \
  "backend:$SITE_BACKUP_DIR/$(basename "$SQL_BACKUP")" || error_exit "Copy failed"

if [ -n "$FILES_BACKUP" ]; then
  log "Copying files backup into container"
  docker compose --project-name "erpnext-$PROJECT_NAME" cp "$FILES_BACKUP" \
    "backend:$SITE_BACKUP_DIR/$(basename "$FILES_BACKUP")" || error_exit "Copy failed"
fi

SQL_IN_CONTAINER="$SITE_BACKUP_DIR/$(basename "$SQL_BACKUP")"

# Drop any empty site created by deploy.sh so restore can rebuild it
if docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
  bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
  log "Existing site found, dropping before restore"
  docker compose --project-name "erpnext-$PROJECT_NAME" exec -T backend \
    bench drop-site "$SITE_NAME" --force --no-backup >/dev/null 2>&1 || true
fi

log "Restoring v15 backup into $SITE_NAME (this upgrades schema to v16 on migrate)"
docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
  bench restore "$SQL_IN_CONTAINER" --site "$SITE_NAME" \
  --mariadb-root-password "$DB_PASSWORD" --admin-password "$ADMIN_PASSWORD" \
  || error_exit "Restore failed"

log "Running migrations (v15 -> v16)"
docker compose --project-name "erpnext-$PROJECT_NAME" exec backend \
  bench --site "$SITE_NAME" migrate || error_exit "Migrate failed"

printf "\033[0;32m%s restored and migrated to v16\033[0m\n" "$SITE_NAME"
