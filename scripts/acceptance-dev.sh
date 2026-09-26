#!/usr/bin/env bash
# Real isolated developer-flow acceptance. Host requires only documented Docker/Bash/Unix tooling.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
OUTPUT="$ROOT/artifacts/dev-acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$"
MODE=full
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT=$2; shift 2;; --secret-boundary-only) MODE=secret-boundary; shift;; *) echo 'usage: acceptance-dev.sh [--output DIRECTORY] [--secret-boundary-only]' >&2; exit 2;; esac
done
[ ! -d "$OUTPUT" ] || [ -z "$(ls -A "$OUTPUT")" ] || { echo 'evidence directory must be new or empty' >&2; exit 2; }
mkdir -p "$OUTPUT"; OUTPUT=$(cd "$OUTPUT" && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/omega dev acceptance.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
ORIGINAL_PATH=$PATH
SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
for name in A B; do
  mkdir -p "$WORK/source $name"
  git -C "$ROOT" archive HEAD | tar -xpf - -C "$WORK/source $name"
done
mkdir -p "$WORK/deny"
for tool in go node yarn corepack npm python python3 jq; do
  cat > "$WORK/deny/$tool" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$OMEGA_ACCEPTANCE_DENIED"
echo 'acceptance: forbidden host development runtime invoked' >&2
exit 97
SHIM
  chmod +x "$WORK/deny/$tool"
done
export OMEGA_ACCEPTANCE_DENIED="$OUTPUT/host-runtime-invocations.log"
: > "$OMEGA_ACCEPTANCE_DENIED"
export PATH="$WORK/deny:$ORIGINAL_PATH"
printf 'case\tstatus\tstarted_at\tfinished_at\tevidence\tdetail\n' > "$OUTPUT/results.tsv"
{
  printf 'source_commit=%s\nfixture_root=%s\n' "$SOURCE_COMMIT" "$WORK"
  uname -sm
  docker version --format 'docker_server={{.Server.Version}} platform={{.Server.Os}}/{{.Server.Arch}}'
  docker compose version
  printf 'Native Linux amd64: NOT EXECUTED; current user has no target.\n'
  printf 'Shared daemon base-image cache retained; project-specific resources initially absent.\n'
} > "$OUTPUT/platform.txt"
docker ps -a --format '{{.ID}} {{.Names}}' > "$OUTPUT/baseline-containers.txt"
docker image ls --format '{{.Repository}}:{{.Tag}} {{.ID}}' > "$OUTPUT/baseline-images.txt"
STEP=setup; STARTED=$(date -u +%FT%TZ); INDEX=0; ACTIVE=''; PLACEHOLDER=''; SUCCESS=false
select_instance() {
  NAME=$1; SRC="$WORK/source $NAME"; INPUT="$SRC/.omega/dev"; INSTANCE=''; PROJECT=''; PORT=''
  if [ -f "$INPUT/instance.env" ]; then
    INSTANCE=$(sed -n 's/^INSTANCE_ID=//p' "$INPUT/instance.env")
    PROJECT="omega-$INSTANCE"
    PORT=$(sed -n 's/^HTTP_PORT=//p' "$INPUT/instance.env")
  fi
}
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$STEP" "$1" "$STARTED" "$(date -u +%FT%TZ)" "$STEP/" "$2" >> "$OUTPUT/results.tsv"; }
begin() { STEP=$1; STARTED=$(date -u +%FT%TZ); INDEX=0; mkdir -p "$OUTPUT/$STEP"; printf '[%s] %s\n' "$STARTED" "$STEP"; }
fail() { echo "$*" >&2; record FAIL "$*"; exit 1; }
assert() { "$@" || fail "assertion failed: $*"; }
run() {
  local expected=$1; shift; INDEX=$((INDEX+1)); local stem="$OUTPUT/$STEP/$INDEX" code=0
  printf 'source=%q input=%q\n' "${SRC:-}" "${INPUT:-}" > "$stem.argv"
  printf '%q ' "$@" >> "$stem.argv"; printf '\n' >> "$stem.argv"
  "$@" > "$stem.stdout" 2> "$stem.stderr" || code=$?
  printf '%s\n' "$code" > "$stem.exit"
  [ "$code" -eq "$expected" ] || fail "expected exit $expected, got $code; see $STEP/$INDEX.stderr"
}
make_cmd() { local command=$1; shift; make -C "$SRC" "$command" "$@"; }
cli() { "$SRC/scripts/omega.sh" --input "$INPUT" -- "$@"; }
container() { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1"; }
sql() { docker exec "$(container db)" psql -U postgres -d omega -v ON_ERROR_STOP=1 -At -c "$1"; }
compose() {
  env -i PATH="$PATH" HOME="$HOME" \
    OMEGA_INPUT_DIR="$INPUT" OMEGA_SOURCE_DIR="$SRC" OMEGA_INSTANCE_ID="$INSTANCE" OMEGA_ENVIRONMENT=dev \
    OMEGA_HTTP_PORT="$PORT" OMEGA_HTTPS_PORT="$((PORT+1))" OMEGA_DOMAIN=localhost \
    OMEGA_UID="$(id -u)" OMEGA_GID="$(id -g)" OMEGA_VERSION=dev \
    OMEGA_API_IMAGE="$PROJECT-api:dev" OMEGA_WEB_IMAGE="$PROJECT-web:dev" \
    OMEGA_CONSOLE_IMAGE="$PROJECT-console:dev" OMEGA_EDGE_IMAGE="$PROJECT-edge:dev" OMEGA_DB_IMAGE=postgres:17.10-alpine \
    docker compose --project-name "$PROJECT" --project-directory "$SRC" --env-file /dev/null -f "$SRC/compose.yaml" -f "$SRC/compose.dev.yaml" "$@"
}
hash() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
inputs_hash() { hash "$INPUT/instance.env" "$INPUT/api.yaml" "$INPUT/migration.yaml" "$INPUT/web.json" "$INPUT/console.json" "$INPUT/secrets/admin" "$INPUT/secrets/migrator" "$INPUT/secrets/runtime"; }
identity() { sql 'SELECT instance_id,environment,installed_at FROM omega.installation'; }
wait_ping() {
  local expected=$1 deadline=$((SECONDS+120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl --max-time 3 --fail --silent "http://127.0.0.1:$PORT/api/v1/ping" > "$OUTPUT/$STEP/ping.json" && grep -q "$expected" "$OUTPUT/$STEP/ping.json"; then return; fi
    sleep 1
  done
  fail "public ping did not reach expected content: $expected"
}
cleanup() {
  local code=$?; trap - EXIT INT TERM
  [ -z "$ACTIVE" ] || kill -TERM "$ACTIVE" 2>/dev/null || true
  [ -z "$PLACEHOLDER" ] || docker rm -f "$PLACEHOLDER" >/dev/null 2>&1 || true
  for name in A B; do
    select_instance "$name"
    if [ -n "$PROJECT" ]; then
      docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.ID}} {{.Names}} {{.Status}}' > "$OUTPUT/final-$name-containers.txt"
      for service in db api web console edge; do
        local cid; cid=$(container "$service")
        [ -z "$cid" ] || docker logs --tail 300 "$cid" > "$OUTPUT/final-$name-$service.stdout" 2> "$OUTPUT/final-$name-$service.stderr" || true
      done
    fi
  done
  if [ "$code" -ne 0 ]; then
    printf 'FAILED; resources preserved for diagnosis. Fixture root: %s\nEvidence: %s\n' "$WORK" "$OUTPUT" >&2
  else
    printf 'Evidence: %s\n' "$OUTPUT"
    [ "$SUCCESS" != true ] || rm -rf -- "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

begin OMEGA-01-02-03-29-cold
select_instance A
assert test ! -e "$INPUT"
run 0 make_cmd dev
select_instance A
wait_ping '"status":"ok"'
run 0 make_cmd status
assert test "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" | wc -l | tr -d ' ')" = 5
for path in /web/ /console/ /web/runtime-config.json /console/runtime-config.json; do
  run 0 curl --max-time 10 --fail --silent --show-error "http://127.0.0.1:$PORT$path"
done
assert test ! -s "$OMEGA_ACCEPTANCE_DENIED"
inputs_hash > "$OUTPUT/initial-inputs.sha256"; identity > "$OUTPUT/initial-identity.txt"
A_PROJECT=$PROJECT; A_PORT=$PORT
record PASS 'Project-cold start from source path with spaces; all five services and public paths; host runtimes forbidden. Shared base cache retained.'

begin OMEGA-16-24-secret-boundaries
for service in api web console; do
  run 0 docker exec "$(container "$service")" sh -c 'test ! -r /workspace/.omega/dev/secrets/admin && test ! -r /workspace/.omega/dev/secrets/migrator && test ! -r /workspace/.omega/dev/.runtime-secrets/db-admin && test ! -r /run/secrets/admin_password && test ! -r /run/secrets/migrator_password'
done
run 0 docker exec "$(container api)" sh -c 'test -r /run/secrets/db_password'
for service in migrate deps; do
  run 0 compose run --rm --no-deps --entrypoint sh "$service" -c 'test ! -r /workspace/.omega/dev/secrets/admin && test ! -r /workspace/.omega/dev/secrets/migrator'
done
for app in web console; do
  for target in secrets/admin secrets/migrator .runtime-secrets/db-admin; do
    run 0 curl --max-time 10 --silent --show-error --output "$WORK/withheld-body" --write-out '%{http_code}' "http://127.0.0.1:$PORT/$app/@fs/workspace/.omega/dev/$target"
    status=$(cat "$OUTPUT/$STEP/$INDEX.stdout")
    case "$status" in 403|404) ;; *) fail "frontend private-file request returned $status instead of403/404";; esac
    for role in admin migrator runtime; do
      if grep -F -q -f "$INPUT/secrets/$role" "$WORK/withheld-body"; then fail 'frontend exposed private credential content'; fi
    done
  done
done
record PASS 'Default .omega credentials hidden from API/frontends/maintenance/dependency source mounts; only API runtime role mounted; both edge @fs paths403/404 and bodies contain no credentials.'
if [ "$MODE" = secret-boundary ]; then
  begin cleanup
  run 0 "$SRC/scripts/dev.sh" dev-reset --confirm "$INSTANCE"
  record PASS 'Targeted correction regression cleaned only its own default-input instance.'
  SUCCESS=true
  exit 0
fi

begin OMEGA-06-repeat
run 0 make_cmd dev
inputs_hash > "$OUTPUT/$STEP/inputs.sha256"; identity > "$OUTPUT/$STEP/identity.txt"
assert cmp "$OUTPUT/initial-inputs.sha256" "$OUTPUT/$STEP/inputs.sha256"
assert cmp "$OUTPUT/initial-identity.txt" "$OUTPUT/$STEP/identity.txt"
assert test ! -e "$INPUT/.lock"
record PASS 'Repeated real startup preserves inputs, secret hashes, installation timestamp, and releases lock.'

begin OMEGA-07-missing-credential
mv "$INPUT/secrets/runtime" "$WORK/saved-runtime"
run 3 "$SRC/scripts/dev.sh" dev
assert test ! -e "$INPUT/secrets/runtime"
assert grep -q 'original runtime credential is missing' "$OUTPUT/$STEP/1.stderr"
assert docker volume inspect "${PROJECT}_db_data"
mv "$WORK/saved-runtime" "$INPUT/secrets/runtime"
run 0 make_cmd dev
identity > "$OUTPUT/$STEP/identity.txt"; assert cmp "$OUTPUT/initial-identity.txt" "$OUTPUT/$STEP/identity.txt"
record PASS 'Existing volume plus missing credential refuses regeneration; same startup succeeds after restoring original.'

begin OMEGA-08-09-14-dependency
cp "$SRC/package.json" "$WORK/package-original.json"
hash "$SRC/yarn.lock" > "$OUTPUT/$STEP/lock-before.sha256"
sed 's/"typescript": "6.0.3"/"typescript": "6.0.2"/' "$WORK/package-original.json" > "$SRC/package.json"
diff -u "$WORK/package-original.json" "$SRC/package.json" > "$OUTPUT/$STEP/fixture.diff" || true
hash "$SRC/package.json" > "$OUTPUT/$STEP/fixture.sha256"
run 1 "$SRC/scripts/dev.sh" dev
assert grep -q 'immutable-dependencies failed' "$OUTPUT/$STEP/1.stderr"
hash "$SRC/yarn.lock" > "$OUTPUT/$STEP/lock-after.sha256"; assert cmp "$OUTPUT/$STEP/lock-before.sha256" "$OUTPUT/$STEP/lock-after.sha256"
cp "$WORK/package-original.json" "$SRC/package.json"
run 0 make_cmd dev
wait_ping '"status":"ok"'
identity > "$OUTPUT/$STEP/identity.txt"; assert cmp "$OUTPUT/initial-identity.txt" "$OUTPUT/$STEP/identity.txt"
record PASS 'Actual immutable dependency failure, unchanged lock, original identity preserved, exact startup retry recovers.'

begin OMEGA-05-recompile
cp "$SRC/services/api/internal/app/server.go" "$WORK/server-original.go"
sed 's/"project": "Omega"/"project": "Omega-probe"/' "$WORK/server-original.go" > "$SRC/services/api/internal/app/server.go"
diff -u "$WORK/server-original.go" "$SRC/services/api/internal/app/server.go" > "$OUTPUT/$STEP/fixture.diff" || true
hash "$SRC/services/api/internal/app/server.go" > "$OUTPUT/$STEP/fixture.sha256"
wait_ping 'Omega-probe'
printf '\nthis is invalid Go syntax\n' >> "$SRC/services/api/internal/app/server.go"
deadline=$((SECONDS+90))
unavailable=false
while [ "$SECONDS" -lt "$deadline" ]; do
  if ! curl --max-time 3 --fail --silent "http://127.0.0.1:$PORT/api/v1/ping" >/dev/null; then unavailable=true; break; fi
  sleep 1
done
assert test "$unavailable" = true
run 0 docker logs "$(container api)"
assert grep -q 'BUILD FAILED' "$OUTPUT/$STEP/1.stderr"
cp "$WORK/server-original.go" "$SRC/services/api/internal/app/server.go"
wait_ping '"project":"Omega"'
record PASS 'Visible source change rebuilt; invalid Go removed old API; compiler diagnosis and recovery observed. No shared Go module exists.'

begin OMEGA-15-pollution
run 0 env COMPOSE_PROJECT_NAME=forbidden-foreign COMPOSE_FILE=/does-not-exist OMEGA_INPUT_DIR=/forbidden OMEGA_INSTANCE_ID=forbidden-foreign "$SRC/scripts/dev.sh" status
assert grep -q "$INSTANCE" "$OUTPUT/$STEP/1.stdout"
assert test -z "$(docker ps -aq --filter label=com.docker.compose.project=forbidden-foreign)"
record PASS 'Conflicting inherited Compose/controlled Omega variables did not alter explicit target.'

begin OMEGA-16-config
cp "$INPUT/api.yaml" "$WORK/api-original.yaml"
printf '\nunknown: true\n' >> "$INPUT/api.yaml"
run 2 "$SRC/scripts/dev.sh" dev
assert grep -q 'prepare-inputs failed' "$OUTPUT/$STEP/1.stderr"
cp "$WORK/api-original.yaml" "$INPUT/api.yaml"
run 0 cli --json config validate
record PASS 'Unknown configuration rejected before application start; valid original restored. Strict CLI/Secret cases additionally covered by API process suite.'

begin OMEGA-19-proxy-rediscovery
old_api=$(container api); old_edge=$(container edge)
old_ip=$(docker inspect --format "{{with index .NetworkSettings.Networks \"${PROJECT}_app\"}}{{.IPAddress}}{{end}}" "$old_api")
assert test -n "$old_ip"
run 0 compose rm -sf api
PLACEHOLDER="$PROJECT-dns-occupant"
run 0 docker run -d --rm --name "$PLACEHOLDER" --label "omega.acceptance.project=$PROJECT" --network "${PROJECT}_app" --ip "$old_ip" --entrypoint sleep "$PROJECT-tools:dev" 300
run 0 compose up -d --no-build --wait --wait-timeout 210 api
new_ip=$(docker inspect --format "{{with index .NetworkSettings.Networks \"${PROJECT}_app\"}}{{.IPAddress}}{{end}}" "$(container api)")
printf 'old_api=%s old_ip=%s new_api=%s new_ip=%s edge=%s\n' "$old_api" "$old_ip" "$(container api)" "$new_ip" "$old_edge" > "$OUTPUT/$STEP/addresses.txt"
assert test "$old_api" != "$(container api)"
assert test "$old_ip" != "$new_ip"
assert test "$old_edge" = "$(container edge)"
wait_ping '"status":"ok"'
run 0 docker rm -f "$PLACEHOLDER"; PLACEHOLDER=''
record PASS 'API changed actual app-network IP while edge container unchanged; old IP occupied by scoped fixture; external ping recovered.'

begin OMEGA-11-down-preserves
run 0 make_cmd down
assert docker volume inspect "${PROJECT}_db_data"
assert test -z "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")"
run 0 make_cmd dev
identity > "$OUTPUT/$STEP/identity.txt"; assert cmp "$OUTPUT/initial-identity.txt" "$OUTPUT/$STEP/identity.txt"
inputs_hash > "$OUTPUT/$STEP/inputs.sha256"; assert cmp "$OUTPUT/initial-inputs.sha256" "$OUTPUT/$STEP/inputs.sha256"
record PASS 'Normal down retained database volume and exact credentials/identity after restart.'

begin OMEGA-08-09-migration
select_instance B
cp "$SRC/services/api/internal/database/database.go" "$WORK/database-original.go"
sed 's/CREATE TABLE omega.installation/CREATE TABL omega.installation/' "$WORK/database-original.go" > "$SRC/services/api/internal/database/database.go"
diff -u "$WORK/database-original.go" "$SRC/services/api/internal/database/database.go" > "$OUTPUT/$STEP/fixture.diff" || true
hash "$SRC/services/api/internal/database/database.go" > "$OUTPUT/$STEP/fixture.sha256"
run 4 "$SRC/scripts/dev.sh" dev
select_instance B
assert grep -q 'migration failed' "$OUTPUT/$STEP/1.stderr"
run 0 sql "SELECT result FROM omega.migration_attempts ORDER BY id DESC LIMIT 1"
assert grep -q 'SQLSTATE 42601' "$OUTPUT/$STEP/2.stdout"
assert test "$(sql 'SELECT count(*) FROM omega.schema_migrations')" = 0
cp "$WORK/database-original.go" "$SRC/services/api/internal/database/database.go"
run 0 make_cmd dev
wait_ping '"status":"ok"'
B_PROJECT=$PROJECT; B_PORT=$PORT
record PASS 'Real PostgreSQL SQL syntax error rolled back migration and journaled failure; same dev entry recovered without replacing volume.'

begin OMEGA-10-isolation
assert test "$A_PROJECT" != "$B_PROJECT"
assert test "$A_PORT" != "$B_PORT"
B_DB=$(container db); B_EDGE=$(container edge)
identity > "$OUTPUT/$STEP/B-identity.txt"
assert test "$(hash "$WORK/source A/.omega/dev/secrets/runtime" | awk '{print $1}')" != "$(hash "$WORK/source B/.omega/dev/secrets/runtime" | awk '{print $1}')"
run 0 curl --max-time 10 --fail --silent "http://127.0.0.1:$A_PORT/api/v1/ping"
run 0 curl --max-time 10 --fail --silent "http://127.0.0.1:$B_PORT/api/v1/ping"
run 2 docker run --rm --network "${PROJECT}_data" --mount "type=bind,src=$WORK/source A/.omega/dev/secrets/runtime,dst=/password,readonly" --entrypoint sh postgres:17.10-alpine -c 'PGPASSWORD=$(cat /password) psql -h db -U omega_runtime -d omega -c "SELECT 1"'
assert grep -q 'password authentication failed' "$OUTPUT/$STEP/3.stderr"
run 0 docker run --rm --network "${PROJECT}_data" --mount "type=bind,src=$INPUT/secrets/runtime,dst=/password,readonly" --entrypoint sh postgres:17.10-alpine -c 'PGPASSWORD=$(cat /password) psql -h db -U omega_runtime -d omega -c "SELECT 1"'
record PASS 'Different instances/projects/ports/volumes/credentials; A credential cannot authenticate to B while B credential succeeds; simultaneous public health.' 

begin OMEGA-37-concurrency-cancel
select_instance A
sql "SET application_name='omega_acceptance_lock'; BEGIN; LOCK TABLE omega.installation IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(120); ROLLBACK" > "$OUTPUT/$STEP/db-lock.stdout" 2> "$OUTPUT/$STEP/db-lock.stderr" & HOLDER=$!
deadline=$((SECONDS+20))
while [ "$(sql "SELECT count(*) FROM pg_stat_activity WHERE application_name='omega_acceptance_lock' AND wait_event='PgSleep'")" != 1 ]; do
  [ "$SECONDS" -lt "$deadline" ] || fail 'database lock holder did not acquire actual lock'; sleep 1
done
"$SRC/scripts/omega.sh" --input "$INPUT" -- doctor > "$OUTPUT/$STEP/operation.stdout" 2> "$OUTPUT/$STEP/operation.stderr" & ACTIVE=$!
deadline=$((SECONDS+20))
while [ ! -d "$INPUT/.lock" ]; do [ "$SECONDS" -lt "$deadline" ] || fail 'maintenance failed to acquire lock'; sleep 1; done
# Verify the actual one-off CLI (not merely an HTTP health probe) reached PostgreSQL lock wait.
deadline=$((SECONDS+30)); task_ip=''
while [ "$SECONDS" -lt "$deadline" ]; do
  task_id=$(docker ps -q --filter "name=${PROJECT}-task-")
  if [ -n "$task_id" ]; then
    task_ip=$(docker inspect --format "{{with index .NetworkSettings.Networks \"${PROJECT}_data\"}}{{.IPAddress}}{{end}}" "$task_id")
    if [ -n "$task_ip" ] && [ "$(sql "SELECT count(*) FROM pg_stat_activity WHERE application_name='omega' AND client_addr='$task_ip'::inet AND wait_event_type='Lock'")" -gt 0 ]; then break; fi
  fi
  sleep 1
done
assert test "$SECONDS" -lt "$deadline"
printf 'maintenance_container=%s database_client_ip=%s\n' "$task_id" "$task_ip" > "$OUTPUT/$STEP/blocked-client.txt"
run 6 "$SRC/scripts/omega.sh" --input "$INPUT" -- doctor
assert grep -q 'operation lock held' "$OUTPUT/$STEP/1.stderr"
kill -TERM "$ACTIVE"; code=0; wait "$ACTIVE" || code=$?; ACTIVE=''
assert test "$code" = 130
assert test ! -d "$INPUT/.lock"
sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='omega_acceptance_lock'" > "$OUTPUT/$STEP/release-lock.stdout"
wait "$HOLDER" || true
run 0 cli --json doctor
wait_ping '"status":"ok"'
assert test -z "$(docker ps -aq --filter "name=${PROJECT}-task-")"
record PASS 'Real blocked maintenance excludes concurrent caller (6), TERM exits130, releases owned locks/tasks, and retry succeeds.'

begin OMEGA-12-reset-boundary
run 3 "$SRC/scripts/dev.sh" dev-reset --confirm wrong-instance
assert docker volume inspect "${PROJECT}_db_data"
cp "$INPUT/instance.env" "$WORK/instance-original.env"
sed 's/ENVIRONMENT=dev/ENVIRONMENT=prod/' "$WORK/instance-original.env" > "$INPUT/instance.env"
run 3 "$SRC/scripts/dev.sh" dev-reset --confirm "$INSTANCE"
cp "$WORK/instance-original.env" "$INPUT/instance.env"
run 0 sql "UPDATE omega.installation SET environment='prod'"
run 3 "$SRC/scripts/dev.sh" dev-reset --confirm "$INSTANCE"
assert grep -q 'database instance/environment does not match' "$OUTPUT/$STEP/4.stdout"
assert docker volume inspect "${PROJECT}_db_data"
run 0 sql "UPDATE omega.installation SET environment='dev'"
run 0 "$SRC/scripts/dev.sh" dev-reset --confirm "$INSTANCE"
if docker volume inspect "${PROJECT}_db_data" >/dev/null 2>&1; then fail 'confirmed reset left database volume'; fi
select_instance B
assert test "$B_DB" = "$(container db)"
assert test "$B_EDGE" = "$(container edge)"
identity > "$OUTPUT/$STEP/B-identity.txt"; assert cmp "$OUTPUT/OMEGA-10-isolation/B-identity.txt" "$OUTPUT/$STEP/B-identity.txt"
wait_ping '"status":"ok"'
record PASS 'Wrong confirmation/prod inputs and actual prod DB identity refused; exact A reset deleted only A; B containers/data/health unchanged.'

begin OMEGA-16-log-secret-audit
for name in A B; do
  for role in admin migrator runtime; do
    if grep -F -l -f "$WORK/source $name/.omega/dev/secrets/$role" "$OUTPUT"/*/*.stdout "$OUTPUT"/*/*.stderr > "$OUTPUT/$STEP/$name-$role.matches"; then fail 'credential appeared in captured stdout/stderr'; fi
  done
done
record PASS 'All six generated credentials absent from captured command stdout/stderr; audit emits filenames only.'
begin cleanup
run 0 "$SRC/scripts/dev.sh" dev-reset --confirm "$INSTANCE"
assert test ! -s "$OMEGA_ACCEPTANCE_DENIED"
record PASS 'All harness database/cache volumes reset through actual selected-instance entry points; no denied host runtime ran.'
begin pending-cross-scope
record NOT_EXECUTED 'OMEGA04 browser HMR, OMEGA13 all-workspace quality checks, full OMEGA16 artifact secret audit and native OMEGA38 belong to companion evidence; this report does not mark them passed.'
SUCCESS=true
