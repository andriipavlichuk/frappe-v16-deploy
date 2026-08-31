# Frappe ERPNext v16 deployment

This repository is a small deployment wrapper around the upstream
[`frappe_docker`](https://github.com/frappe/frappe_docker) project. It creates a
custom Frappe/ERPNext v16 image, starts the ERPNext and MariaDB Compose stacks,
and can restore a v15 site backup before migrating it to v16.

The two repositories have different jobs:

- This repository holds the project configuration and deployment scripts.
- `frappe_docker` supplies the Compose files and the custom-image Containerfile.

Do not use this repository itself as the **Frappe Docker directory**. The setup
script can clone `frappe_docker` for you into a separate directory such as
`~/frappe_docker`.

## Prerequisites

- Docker Engine with the Docker Compose plugin and BuildKit support
- Git
- A free local port for HTTP deployments, or a domain whose DNS points to the
  server for Traefik deployments

## Create a project

Run the interactive initializer from this repository:

```bash
bash new-project.sh
```

It asks for the project and site names, deployment type, image versions and
secrets. At the **Frappe Docker directory** prompt, accept the default
`~/frappe_docker` or enter another nonexistent directory. The script clones the
upstream repository there. If the directory already exists, it must be a
compatible `frappe_docker` checkout containing `compose.yaml` and
`images/custom/Containerfile`.

The initializer writes an ignored, mode-600 `config.env` and creates the ignored
`gitops/` output directory. For a Traefik deployment it also creates
`gitops/traefik.env` and `gitops/acme.json`.

## Choose applications

Edit [`apps.json`](apps.json) manually before building. It is the complete list
of Frappe applications cloned into the custom image. Keep `erpnext`, then add
every application your project needs, with its repository URL and compatible
branch:

```json
[
  {"url": "https://github.com/frappe/erpnext", "branch": "version-16"},
  {"url": "https://github.com/frappe/hrms", "branch": "version-16"}
]
```

Changing `apps.json` requires a rebuild. The list makes applications available
in the image; on a new site `deploy.sh` installs ERPNext automatically. Install
any additional application on that site afterwards, for example:

```bash
docker compose --project-name "erpnext-<project-name>" exec backend \
  bench --site "<site-name>" install-app <app-name>
```

When migrating an existing site, every application already installed on that
site must be present in `apps.json` before the image is built.

## Build and deploy

```bash
bash build.sh
bash deploy.sh
```

`build.sh` creates the image specified by `IMAGE_TAG`. `deploy.sh` renders the
Compose configuration into `gitops/`, starts a shared MariaDB container and the
ERPNext stack, creates the site when needed, and runs migrations. If the image
is not present locally, `deploy.sh` builds it automatically.

For local deployments (`MODE=http`), open `http://localhost:<HTTP_PORT>/`.
For server deployments (`MODE=traefik`), make sure DNS for `DOMAIN` points to the
server before deployment; the initializer records the Let's Encrypt email in
`gitops/traefik.env`.

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
- `apps.json` — manually maintained application list for the custom image.
- `build.sh` — custom Docker image build.
- `deploy.sh` — Compose rendering, stack startup, site creation and migration.
- `migrate.sh` — v15 backup restore and v16 migration.

## Operational notes

- Change the generated database and administrator passwords before production use.
- `deploy.sh` updates `compose.yaml` and the MariaDB override inside the configured
  `frappe_docker` checkout. Treat that checkout as deployment-managed.
- Generated configuration, Compose output and certificate data are intentionally
  excluded from Git.
