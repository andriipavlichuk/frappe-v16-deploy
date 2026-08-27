# slife v16 deployment scripts

Portable script set to deploy Frappe/ERPNext **v16** (with `erpnext`, `payments`,
`lms`, `hrms`, `raven`) and migrate an existing v15 site via backup + `bench migrate`.

Works locally (HTTP, site `slife.localhost`) and on the server (Traefik + TLS,
site `slife.guru`) by editing `config.env`.

## Files
- `config.env` — all parameters (project, site, paths, image tag, secrets, mode).
- `apps.json` — the frappe-made apps baked into the image (v16/develop branches).
- `build.sh` — builds the custom image from `frappe_docker_betop` + `apps.json`.
- `deploy.sh` — renders compose, starts MariaDB + ERPNext, creates/migrates site.
- `migrate.sh` — restores a v15 `bench backup` and upgrades it to v16.

## Local (slife.localhost, HTTP)
1. Edit `config.env` (defaults already set for local: `MODE=http`, `SITE_NAME=slife.localhost`).
2. `bash build.sh`            # builds `erpnext-16:1.0.0`
3. `bash deploy.sh`           # starts stack on http://localhost:8080
4. To migrate your real site: copy the v15 backup next to this folder, then
   `bash migrate.sh /path/to/<ts>_database.sql.gz [/path/to/<ts>_files.tar]`

## Server (slife.guru, Traefik + TLS)
1. Copy this folder to the server; edit `config.env`:
   - `SITE_NAME=slife.guru`, `DOMAIN=slife.guru`
   - `FRAPPE_DOCKER_PATH=/root/frappe_docker_betop`, `GITOPS_PATH=/root/gitops-slife16`
   - `IMAGE_TAG=slifedev/erpnext-16:1.0.0`
   - `MODE=traefik`
2. Create `gitops/traefik.env` (see your existing `slife-scripts/traefik.env`):
   `TRAEFIK_DOMAIN=slife.guru`, `EMAIL=support@slife.guru`, `HASHED_PASSWORD=...`
3. `bash build.sh` (or `docker push` the already-built image).
4. `bash deploy.sh`
5. `bash migrate.sh /path/to/v15_database.sql.gz [/path/to/v15_files.tar]`
6. If Traefik started before DNS was ready, restart it so the cert is issued.

## Notes
- The image build uses `frappe_docker_betop`'s Containerfile (APPS_JSON_BASE64),
  which matches the server, so the scripts are identical locally and on the server.
- `deploy.sh` mutates `compose.yaml` (image tag) and
  `overrides/compose.mariadb-shared.yaml` (container name) inside the frappe_docker
  repo — that is by design (same as the original slife-scripts flow).
- Change `DB_PASSWORD` / `ADMIN_PASSWORD` in `config.env` before any real use.
