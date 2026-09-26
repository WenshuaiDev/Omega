# Development and Compose contract (#16)

Explicit environment input directory (default `.omega/dev`, override `scripts/dev.sh COMMAND --input DIRECTORY`) is independent of source/releases. Stable `instance.env` has only `ENVIRONMENT`, `INSTANCE_ID`, `HTTP_PORT`, `HTTPS_PORT`, `DOMAIN`; parse as data, never source. dev ID generated once; test/prod IDs explicit. Files: `api.yaml`, `migration.yaml` (complete config), `web.json`, `console.json`, `secrets/{admin,migrator,runtime}` (0600), release TLS `tls/{cert.pem,key.pem}`. YAML password_file is `/run/secrets/db_password`; mounts select the role. Runtime cfg `/etc/omega/app.yaml`. Instance project `omega-${INSTANCE_ID}`; DB volume `${project}_db_data` persists across versions. Input and instance locks prevent concurrent mutation.

Compose files: base `compose.yaml`; dev adds `compose.dev.yaml`; formal adds `compose.release.yaml` and `compose.test.yaml` or `compose.prod.yaml`. Explicit interpolation env (sanitized shell) supplies `OMEGA_INPUT_DIR`, `OMEGA_SOURCE_DIR`, `OMEGA_INSTANCE_ID`, `OMEGA_ENVIRONMENT`, `OMEGA_HTTP_PORT`, `OMEGA_HTTPS_PORT`, `OMEGA_DOMAIN`, `OMEGA_UID`, `OMEGA_GID`, `OMEGA_VERSION`, `OMEGA_API_IMAGE`, `OMEGA_WEB_IMAGE`, `OMEGA_CONSOLE_IMAGE`, `OMEGA_EDGE_IMAGE`, `OMEGA_TOOLS_IMAGE`, `OMEGA_DB_IMAGE`. Release wrappers must select all image refs explicitly and check image IDs; formal models set pull_policy never, platform linux/amd64, no build or source mounts. Bind ports formal 80/443 via provided values; dev only 127.0.0.1 HTTP.

Services db, api, web, console, edge; `migrate` one-off profiled `tools` (same API image with migration config/secret and omega entrypoint). Development `deps` one-off installs Yarn immutable as same user as app. Tools image built from infra/tools/Dockerfile includes Python/PyYAML and OpenSSL; `python /tools/inputs.py validate /inputs ENV` validates ordinary files, runtime JSON, file modes and TLS; `render /inputs /output dev|test|prod` produces edge nginx.conf from image templates. Release must run tools with --network none --pull never and mounts, then mount generated file at /etc/nginx/nginx.conf (OMEGA_INPUT_DIR/edge/nginx.conf).

Database bootstrap only runs on empty PostgreSQL data via `/docker-entrypoint-initdb.d/10-omega.sh`; no schema/business objects. Postgres image copies no secret; admin/migrator/runtime files mounted only on DB; API only runtime; migrate only migrator. Runtime SQL objects/default grants owned by backend.

Implementation/evidence details are appended after verification. Native Linux amd64 validation remains pending.

## Implemented commands

`make dev` and `./scripts/dev.sh dev --input '/path with spaces/inputs'` prepare
stable dev inputs, build fixed images, stop apps for dependency/migration changes,
install immutable Yarn dependencies once, run explicit migration and metadata
initialization, then wait for health and five edge HTTP paths. Each phase exits
nonzero on error and preserves volumes. Per-input and per-project mkdir locks
carry an ownership token; signals remove only their own locks/one-off container.
Stale locks after host kill/power loss are refused with their exact location for
operator inspection, never stolen from another command.

`make down` retains all volumes. `make status` prints Compose runtime/health,
entry, disk usage and external ping; `make logs` prints bounded recent logs.
`make dev-reset` displays the selected input/project/volumes, requires the exact
ID (or `--confirm ID` for automation), validates dev ownership and actual DB
identity before deletion, and retains inputs. An unbound/broken DB is deliberately
refused for normal reset; diagnose the isolated instance first. `make check` /
`make test` delegate to independently owned acceptance scripts.

Dev volume mounts include Go cache, root and nested node_modules and `.yarn`;
only the explicit cache setup task runs root, changing ownership solely inside
those named cache volumes. Applications run host UID and cannot change Docker.
Source mountpoints are first created by the host developer. Release applications
are nonroot/read-only. The tools image uses Python 3.13.7 / PyYAML 6.0.2 / OpenSSL
3.5.8-r0; edge uses Nginx 1.28.0-alpine; database PostgreSQL 17.10-alpine.

Staged secrets are mode **0400**, each owned by its actual container user: dev API
host UID/GID, formal API10001, PostgreSQL70, Nginx101. Private staging directory is
0700 owned by the host input owner. Render API UID/GID optional arguments:
`render /inputs /inputs/edge dev UID GID` (formal default10001). Render runs root
inside tools only to prepare these ownership-specific copies. No original secret
mode or value changes. Public proxy directory is0755 and contains no secrets.

## Initial verification (2026-09-26, macOS arm64 / Docker Linux arm64)

- `bash -n scripts/dev.sh` passed.
- Pinned tools Docker image built successfully; first proposed OpenSSL revision
  was unavailable, corrected to actually installed3.5.8-r0.
- Tools init/validate/render worked under an input directory containing spaces.
- All three final Compose models parsed with explicit variables and env-file.
- Live isolated PostgreSQL technical initialization and health checked separately.
- Full application startup remains to be run after API/frontend branch integration.
- Native Linux amd64 validation remains pending; no native evidence is claimed.
