# Frappe ERPNext v16 deployment

This repository is a small, self-contained deployment wrapper for Frappe/
ERPNext v16. It creates a custom image, starts the ERPNext and MariaDB Compose
stacks, and can restore a v15 site backup before migrating it to v16.

The Compose files, Containerfile, and support scripts under [`docker/`](docker)
are vendored from the upstream
[`frappe_docker`](https://github.com/frappe/frappe_docker) project and
parameterized to fit this repo (see [Files](#files)) — there is no external
`frappe_docker` checkout to clone or manage. To pull in an upstream fix, diff
`docker/` against a fresh `frappe_docker` checkout and re-apply what's
relevant by hand; `docker/compose.yaml` notes the commit it was vendored from.

## Prerequisites

- Docker Engine with the Docker Compose plugin and BuildKit support
- Git
- `jq`
- A free local port for HTTP deployments, or a domain whose DNS points to the
  server for Traefik deployments

## Create a project

Run the interactive initializer from this repository:

```bash
bash new-project.sh
```

It asks for the project and site names, deployment type, image versions and
secrets.

The initializer writes an ignored, mode-600 `config.env` and creates the ignored
`gitops/` output directory. For a Traefik deployment it also creates
`gitops/traefik.env` and `gitops/acme.json`.

## Choose applications

Applications are split across two manually maintained files, by how often they
change:

- [`apps.json`](apps.json) — stable apps (`erpnext`, and anything else that
  rarely changes). Installed by the first, `bench init` app layer.
- [`apps.custom.json`](apps.custom.json) — fast-moving apps you iterate on
  often. Installed by a second, later `bench get-app` layer.

Both use the same format — repository URL and compatible branch:

```json
[
  {"url": "https://github.com/frappe/erpnext", "branch": "version-16"},
  {"url": "https://github.com/frappe/hrms", "branch": "version-16"}
]
```

This split exists purely to keep Docker build caching effective: `build.sh`
invalidates the `apps.json` layer with a hash of that file, but invalidates the
`apps.custom.json` layer using each app's *live* branch HEAD (via
`git ls-remote`) instead of the file's contents. That means a new commit on a
custom app's branch rebuilds only that small, dependency-light layer — the
`frappe`/`erpnext` layer stays cached and untouched. Editing `apps.json` (or
adding/removing an app in `apps.custom.json`) still busts the corresponding
layer as expected.

On a **new** site, `deploy.sh` installs ERPNext first and then every other app
baked into the image (from both files). For an existing site, install a newly
added application manually, for example:

```bash
docker compose --project-name "erpnext-<project-name>" exec backend \
  bench --site "<site-name>" install-app <app-name>
```

When migrating an existing site, every application already installed on that
site must be present in `apps.json` or `apps.custom.json` before the image is
built.

## Build and deploy

```bash
bash build.sh
bash deploy.sh
```

`build.sh` builds the image specified by `IMAGE_TAG` using
[`docker/Containerfile`](docker/Containerfile), customized for the two-layer
app install described above. `deploy.sh` renders the Compose configuration
from [`docker/compose.yaml`](docker/compose.yaml) and its overrides into
`gitops/`, starts a shared
MariaDB container and the ERPNext stack, creates the site when needed, and runs
migrations. If the image is not present locally, `deploy.sh` builds it
automatically.

For local deployments (`MODE=http`), open `http://localhost:<HTTP_PORT>/`.
For server deployments (`MODE=traefik`), make sure DNS for `DOMAIN` points to the
server before deployment. For server projects, the initializer asks for the
Let's Encrypt email and a precomputed Traefik dashboard password hash, then
writes the expected `TRAEFIK_DOMAIN`, `EMAIL`, and `HASHED_PASSWORD` variables
to `gitops/traefik.env`.

## Migrate a v15 site

First create a current backup from the v15 site with `bench backup`. After the
v16 stack is deployed and the required apps are in the image, run:

```bash
bash migrate.sh /path/to/<timestamp>_database.sql.gz [path/to/<timestamp>_files.tar]
```

The script copies the backup into the backend container, replaces any empty
site created during deployment, restores the database, and runs `bench migrate`.

## Files

- `new-project.sh` — interactive project initialization.
- `config.env.example` — reference configuration; `config.env` is the local,
  ignored configuration used by the scripts.
- `apps.json` — manually maintained list of stable applications for the custom
  image.
- `apps.custom.json` — manually maintained list of fast-moving applications for
  the custom image (see [Choose applications](#choose-applications)).
- `docker/` — vendored, parameterized `frappe_docker` files this project
  actually uses: `Containerfile` (split into a stable-apps layer and a
  custom-apps layer), `compose.yaml`, `example.env`, `overrides/*.yaml`
  (mariadb-shared, redis, multi-bench, traefik and their SSL variants), and
  `resources/core/*` (nginx template/entrypoint, container entrypoint/start
  scripts) that the Containerfile copies into the image.
- `build.sh` — custom Docker image build.
- `deploy.sh` — Compose rendering, stack startup, site creation and migration.
- `migrate.sh` — v15 backup restore and v16 migration.

## Operational notes

- Change the generated database and administrator passwords before production use.
- `docker/compose.yaml` and `docker/overrides/compose.mariadb-shared.yaml` take
  `IMAGE_TAG`/`PROJECT_NAME` via `${VAR}` interpolation from `config.env`
  (`build.sh`/`deploy.sh`/`migrate.sh` export it with `set -a`); nothing under
  `docker/` is edited in place at build or deploy time.
- Generated configuration, Compose output and certificate data are intentionally
  excluded from Git.
