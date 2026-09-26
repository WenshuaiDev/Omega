# Instance inputs

`make dev` creates `.omega/dev` once. Select a separate complete replacement with
`./scripts/dev.sh dev --input '/absolute/path with spaces/instance'`. Subsequent
runs preserve files and passwords. Edit the selected complete YAML/JSON files;
there is no recursive merge or hidden `.local` overlay. Environment is only
`dev`, `test`, or `prod`; development commands refuse test/prod.

For formal targets copy `templates/` to an external private instance directory,
then replace the environment, instance ID, ports, domain, and public release
version consistently. Add `secrets/admin`, `secrets/migrator`, `secrets/runtime`
as independent mode `0600` files containing different randomly generated values
(at least 32 single-line characters). Supply `tls/cert.pem` and a mode `0600`
`tls/key.pem`. No real secrets are included in templates or images. Production
requires explicit inputs and uses the same images already verified in test.

`infra/tools/inputs.py` runs inside the pinned tools image. It rejects duplicate,
unknown, missing and incorrectly typed fields and validates the actual TLS
hostname, expiry and key match before rendering the proxy. Application CLI
validation remains authoritative for app semantics. Tools rendering creates
`.runtime-secrets/` (host owner, mode `0700`) with separate files owned by the
actual consuming container UID and mode `0400`. Originals remain unchanged.
Only each required file is mounted, never the entire secret directory. DB
initialization sees its three credentials, API sees runtime only, migration
sees migrator only, frontend sees none. Never publish the input directory.

The generated `edge/maintenance` marker, if present, makes the HTTPS/app edge
return `503`; release scripts own maintenance sequencing. Normal development
never removes such a marker from another environment.

Development input paths inside the source tree must be `.omega` or a descendant
of `.omega`; otherwise startup refuses before generating credentials or starting
containers. Inputs outside the source tree remain supported, including paths
with spaces. Every development container that reads the source (API, maintenance,
dependency installer and both frontends) shadows `/workspace/.omega` with an
empty, read-only mode0000 tmpfs. The source bind therefore cannot bypass the
role-specific secret mounts. Edge explicitly rejects paths containing `/.omega/`,
including Vite `@fs` URLs, with404. Keep any managed private instance files only
in the selected supported locations.
