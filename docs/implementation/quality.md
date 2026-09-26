# Manual quality entry points (#21)

`make check` / `scripts/check.sh` and `make test` / `scripts/test.sh` use Bash and
Docker on the host. `--output DIRECTORY` selects evidence; `--timeout SECONDS`
bounds each stage (1800 default). Check's production platform is linux/amd64;
other `--platform` values are rejected. Source is the current Git-tracked and
nonignored untracked content, copied read-only into a disposable named volume.
The original source and dependency manifests are hash-checked after execution.
Do not edit source during a check. Reports identify HEAD and dirty paths, rather
than pretending a dirty candidate is an immutable released commit.

The shared runner derives Go modules from `go work edit -json`, rejects omitted
modules and escaping local replacements, checks format/vet/module checksums,
executes tests and builds. Yarn enumerates actual workspace members, validates
required scripts and consistent exact dependency/tool pins, installs immutable,
then runs format/type/lint/test and applicable builds. A unique real PostgreSQL
instance enables the API/CLI process tests; no user database is used. All shell
sources also undergo Bash syntax validation. The pinned tools image supplies
Python/PyYAML/OpenSSL to inspect three final Compose JSON models including all
profiles, avoiding silent omission of maintenance/dependency services.

Formal model validation rejects source builds/mounts (the PostgreSQL bootstrap
material is explicitly allowed), unsafe permissions/ports, plaintext credential
environment variables, developer commands and automatic pulls. Negative policy
tests mutate realistic final models and require rejection. This supplements,
not replaces, actual offline/HTTP/browser failure exercises in #18.

The full check discovers service/app/infrastructure Dockerfiles and builds actual
Linux amd64 images. It verifies actual image architecture, version/revision
labels, and API/omega binary versions. Images and test containers/networks/volume
are unique to the run and cleaned on exit; Docker build cache is retained. Test
mode omits static checks and production builds but retains all workspace tests,
the real database and policy regression tests. No CI is introduced.

## Verified locally 2026-09-26

Host Darwin arm64; Docker Desktop Linux arm64, Docker29.8.0/Compose5.5.1. Source
baseline `30f5abc44b736fcb771eed7507cbbadeb582bba9` with this quality implementation
as untracked files; exact dirty listing is in each environment report.

- Full `scripts/check.sh --output '/tmp/omega21 check final'`: exit0. Go format,
  vet, checksum verification, real PostgreSQL process tests and build passed.
  Both apps and the actual shared frontend package passed formatting, type/lint,
  all24 tests and applicable production builds. Three complete Compose models
  passed. Five production images built as linux/amd64; actual labels and API/CLI
  binary versions matched; original source and dependency hashes unchanged.
- `scripts/test.sh --output /tmp/omega21-test-evidence-2`: exit0. Real API/CLI
  PostgreSQL scenarios,24 frontend tests and2 policy regression tests passed.
- Reports are local execution evidence at the paths above, not bundled proof of
  native Linux amd64 or offline deployment. Native target acceptance remains #20.

An early runner attempt used a different ephemeral admin password, revealing the
existing API process test's literal `postgres:admin-secret` DSN replacement.
The runner now honors that existing test fixture. Another initial check omitted
Compose profiles; it failed required-service validation and was corrected to
render `--profile '*'`. Neither failed attempt is recorded as a pass.
