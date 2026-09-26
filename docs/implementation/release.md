# Offline release and operations (#17)

The target requires Linux amd64, Docker Engine/CLI supporting `docker image save
--platform` and platform-specific inspect (API 1.49+), Compose v2+ with `--wait`/JSON config, Bash, curl, tar,
SHA-256 (`sha256sum` or `shasum`), and standard Unix utilities. Go, Node, Yarn,
Python, jq, source code and registry access are not target prerequisites. Docker
access is operator authority; application/maintenance/tools containers never
mount its socket. Native Linux amd64 acceptance remains a separate pending task.

## Build once and transfer

From a clean committed checkout in the online build environment:

```bash
./scripts/build-release.sh 1.0.0-rc1 /absolute/output/omega-1.0.0-rc1
```

The clean committed tree is frozen with `git archive` before building, so later
workspace edits cannot mix source revisions. This builds API, web, console, edge and tools for Linux amd64, selects PostgreSQL
17.10, and exports all six images in one archive. API and omega come from the same
image/commit; the actual binary supplies the schema compatibility range. Every
file and image content ID/platform is recorded in `manifest.tsv`. Build evidence
explicitly does not claim test acceptance. The materials include runtime Compose
and database technical initialization, credential-free complete config templates,
operator scripts and this guide; no repository checkout, dev images or credentials.

Record the emitted archive and manifest SHA256 values through a separately
trusted channel. Transfer the archive and trusted bootstrap scripts
`scripts/import-release.sh`, `scripts/release-common.sh` and `scripts/process.sh` (preserve their
relative locations). A checksum delivered only inside the same archive is not
publisher authentication. With this independently trusted bootstrap:

```bash
./scripts/import-release.sh /transfer/omega-1.0.0-rc1.tar TRUSTED_ARCHIVE_SHA256 /opt/omega/releases/1.0.0-rc1
```

The outer trusted hash is checked before extraction or image loading. Absolute
paths, traversal, symlinks and special archive members are rejected. Imported
public file modes are preserved without restoring archive owners or privileged
mode bits, including the PostgreSQL bootstrap executed by UID70. Before any
extraction or image load, the local destination reserves one archive working set
plus512MiB and the Docker filesystem reserves two plus512MiB; a shared filesystem
reserves their combined three working sets plus512MiB. Run the importer on the
actual target host so its Docker root filesystem can be measured. These bounded
preflight reserves do not replace ongoing disk-capacity monitoring. Imported
image IDs and platforms must match; reference names alone are insufficient.
Never repackage a modified directory while retaining old evidence. A new evidence
wrapper may reference the original manifest without rebuilding its images.

## Explicit inputs and deployment

Copy `templates/` into an independent directory such as `/etc/omega/test-a`.
Set all five `instance.env` fields; provide complete `api.yaml`, `migration.yaml`,
`web.json` and `console.json`. The JSON version must equal the selected release.
The instance ID is stable for all releases and determines the Compose project and
database volume. Input paths may contain spaces, but not commas or newlines.
Ordinary YAML, public JSON and the public certificate must be readable by their
nonroot container users (mode0644); their parent input directory may remain0700.

Provide `secrets/admin`, `secrets/migrator`, `secrets/runtime` (independent random
single-line values at least32 characters, mode0600), `tls/cert.pem` and
`tls/key.pem` (mode0600). TLS must match DOMAIN, have matching key and more than
24 hours remaining validity. Certificates should include the required trust chain.
The tools container validates these inputs without network, then stages mode0400
copies for actual consumer UIDs (API10001, PostgreSQL70, Nginx101). Inputs and
Secret values are never put in the release. Missing credentials on an existing
volume are a hard error; no automatic regeneration or password rotation occurs.

```bash
/opt/omega/releases/1.0.0-rc1/materials/scripts/release.sh deploy \
  --env test --input /etc/omega/test-a --version 1.0.0-rc1 \
  --manifest-sha256 TRUSTED_MANIFEST_SHA256
```

Every command requires those same four explicit options. Inherited `OMEGA_*`,
`COMPOSE_*`, and `.env` values cannot change interpolation. The selected Docker
context/connection remains the operator's normal Docker selection; inspect it
before operating. Instance/input locks serialize changes across release versions.
Locks left by power loss are never stolen; inspect their recorded owner before
manually removing only the exact stale lock.

Preflight checks trusted files, all local image IDs/platforms, input completeness,
TLS, volume identity, final Compose policy, candidate configuration and real
database status. All Compose images use content IDs, `pull_policy: never` and
`--no-build`; absent or retagged images fail before maintenance. PostgreSQL major
version upgrades are outside this workflow.

Deployment enters maintenance, stops application writes, explicitly migrates and
ensures metadata, starts candidate containers, checks actual running IDs and
health, and verifies TLS/routes/public configuration/API version. Edge serves503
to external clients throughout. An operator tools container sharing only edge's
network namespace verifies ordinary routes through TLS over loopback; this is
the documented loopback maintenance exemption, not an exposed endpoint or
header bypass. The public published TLS ingress is separately required to return
503. Only after all checks pass is the maintenance marker removed.

Failures/cancellation retain volumes, the maintenance marker when entered, and
`INPUT/.release/runs/<operation>/`: completed phases, selected version/commit/hash,
actual running content IDs, container running/health states, bounded logs, and
CLI migration/status outputs. No database downgrade or automatic application
rollback occurs. Fix the diagnosed input/environment and explicitly retry. A
failed migration can leave the prior application stopped; this is intentional.

## Promotion, rollback and maintenance

Promote the exact tested archive and manifest to prod, record the test evidence
against that manifest, and deploy with `--env prod` plus independent prod inputs
and TLS. Never rebuild for promotion. Store acceptance evidence outside immutable
release directories; each target run records the same manifest hash and IDs.

For rollback select the verified **old release directory**, its original manifest
SHA, old version and matching complete configuration/runtime JSON. Invoke
`rollback` instead of `deploy`. Its old `omega doctor` checks the current real
database schema, published migration checksums and environment/instance before
entering maintenance. Incompatible old binaries refuse before switching. A
compatible rollback skips migrations and metadata writes; the database is never
downgraded. Keep the original release archives for all supported rollback targets.

`status` shows runtime and health separately, maintenance, successful release
record and disk usage. `logs` shows bounded recent output; Docker logging rotates
at10MiB times3. `down` stops without deleting persistent volumes. There is no
test/prod reset or backup/restore operation.

Standalone application maintenance uses the packaged same-version CLI with the
same explicit input, identity, trusted manifest, image verification and locks:

```bash
./materials/scripts/omega-release.sh --env test --input /etc/omega/test-a \
  --version 1.0.0-rc1 --manifest-sha256 TRUSTED_MANIFEST_SHA256 -- --json doctor
```

The command after `--` is `version`, `config validate`, `doctor`, `health check`,
`db status`, `db migrate` or `data ensure`; CLI exit codes are preserved. Config
paths come only from the selected instance. Database diagnostics and writes use
the migration role; HTTP readiness uses a fresh runtime-role CLI container in the
selected running API's network namespace. No admin credential is mounted.
Maintenance writes check any existing API's actual version and real database
state, enable maintenance and stop only a previously running API. They restart
only that API after success; an already stopped API remains stopped with
maintenance enabled. A failure preserves maintenance/data for diagnosis and
retry. Standalone commands never start the database or initialize an HTTP server;
first deployment remains the explicit `deploy` sequence. Production requires all
four options and matching prod configuration/database identity, just like test.

For certificate renewal replace original TLS inputs with complete valid files and
invoke `tls-reload` using the current release and same four explicit options.
Preflight validates hostname/key/expiry, stages the consumer key and performs a
controlled edge recreation to refresh bind-mounted inodes, followed by TLS smoke.
Use planned maintenance; this is not zero-downtime reload.
Replace original certificate/key files atomically. Changed staged TLS keys also
use atomic replacement, preserving the old running edge's certificate/key pair
if a subsequent preflight fails; unchanged credentials retain their inodes.

## Repeatable isolated offline drill

Build the acceptance-only harness while online, then run the drill with one exact
candidate archive/hash/version/manifest and a new evidence directory:

```bash
docker build --platform linux/amd64 -t omega-acceptance-dind:29.8.0 -f infra/acceptance/Dockerfile .
./scripts/acceptance.sh release --output /output/new-evidence \
  --archive /output/omega.tar --archive-sha256 ARCHIVE_SHA \
  --version VERSION --manifest-sha256 MANIFEST_SHA \
  --harness-image omega-acceptance-dind:29.8.0 \
  --old-archive /output/previous.tar --old-archive-sha256 PREVIOUS_ARCHIVE_SHA \
  --old-version PREVIOUS_VERSION --old-manifest-sha256 PREVIOUS_MANIFEST_SHA
```

The four old-candidate options are required and must identify a distinct old version,
archive and manifest; otherwise the drill refuses before running any suite. The script owns a unique privileged **acceptance daemon**
with networknone and its own Docker data volume, never the host socket. It mounts
only archives and operator fixtures, records initially empty target state and
blocked daemon/application egress. A Docker-enabled UID1000 imports the real
bundle and cold-deploys test, proving ordinary-user archive permissions. It then
deploys test and prod with identical
images. It exercises corruption, missing/retagged image refusal, input ownership,
actual readiness/migration SQL failures, maintenance retention, compatible and
incompatible rollback, cancellation/locking, separate concurrent instances and TLS
renewal. Known private fixture markers are scanned across package files, logs,
image config/history and raw/decompressed exported layers without printing them.
Success removes only its owned daemon/volume; failure stops and retains its
container (including private fixture inputs) and owned data volume, recording
their exact names for inspection. The harness source and captured
command log make the drill repeatable. It does not claim native platform support
when run through emulation, nor real production delivery.

## Evidence boundaries

Build/package verification and local Linux amd64 emulation are distinct from
native Linux amd64 acceptance. The latter is **not executed: user currently has
no target host and explicitly retains this acceptance todo**. Offline acceptance
must run in an isolated daemon with external network blocked, no host socket and
initially empty image store, prove daemon and application egress rejection, then
deploy these actual images. The acceptance report must distinguish successful
checks, refused corruption/missing image cases, fault injection and remaining
unexecuted scenarios; package creation alone is not full acceptance.

The [2026-09-26 release acceptance record](../acceptance/2026-09-26/release/README.md)
captures the complete local offline rc7 pass through the unified entrypoint,
including ordinary UID1000 import/cold deployment, actual UID70 bootstrap access,
formal maintenance CLI commands, same-image promotion, failure retention, TLS
rotation and an actual rc4 rollback without schema changes. Twelve private
fixture markers were absent from 494 package/log/image checks. Candidate source
was `4f6f5b3a2b1f847f4f9fa1ca1f5f94ff56c7930d`; the dispatcher ran at
`578cae2a4b62662d834225f7ee9ccdf2982b37f3` after an acceptance-only correction
replaced a numerical mode assertion with the real consumer permission check.
The original rc7 archive was unchanged. Its archive SHA256 is
`5723efe8e9ad447c681111ab7793940154e4e24ad1ff9c3777d5b45f0cd06b17` and
manifest SHA256 is
`341fc4435b8cb914c317bb446ddd8a972ce267299502a86446f9ba5c38c5de9e`.
Both the successful drill's resources and the earlier failed assertion's owned
daemon/volume were removed after evidence capture. This is Linux amd64 emulation
on Docker Desktop/macOS arm64; native Linux amd64 acceptance remains pending #20.
