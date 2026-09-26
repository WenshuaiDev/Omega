#!/usr/bin/env bash
# Source-free target operations; no registry fallback, build, DB down migration,
# secret generation, or host Python/jq dependency.
set -Eeuo pipefail
umask 077
MATERIALS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BUNDLE=$(cd "$MATERIALS/.." && pwd -P)
source "$MATERIALS/scripts/release-common.sh"
COMMAND=${1:-}; [ "$#" -gt 0 ] && shift
ENVIRONMENT=''; INPUT=''; VERSION=''; TRUSTED=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || fail 'every option requires a value'
  case "$1" in
    --env) ENVIRONMENT=$2 ;; --input) INPUT=$2 ;; --version) VERSION=$2 ;; --manifest-sha256) TRUSTED=$2 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift 2
done
case "$COMMAND" in deploy|rollback|status|logs|down|tls-reload) ;; *) fail 'expected deploy, rollback, status, logs, down or tls-reload' ;; esac
case "$ENVIRONMENT" in test|prod) ;; *) fail 'explicit --env test or prod required' ;; esac
[ -n "$INPUT" ] && [ -n "$VERSION" ] || fail '--input and --version required'
prerequisites
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'target host must be Linux amd64; run on target, not development macOS'
[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" = linux/x86_64 ] || fail 'target Docker daemon must be Linux amd64'
verify_manifest "$BUNDLE" "$TRUSTED"
[ "$VERSION" = "$RELEASE_VERSION" ] || fail 'explicit version differs from verified release'
verify_images
INPUT=$(cd -- "$INPUT" && pwd -P)
case "$INPUT" in "$BUNDLE"|"$BUNDLE"/*|*$'\n'*|*','*) fail 'inputs must be outside release and use a Docker-compatible path' ;; esac
[ -f "$INPUT/instance.env" ] || fail 'complete independent instance inputs required'
INSTANCE_ID=''; HTTP_PORT=''; HTTPS_PORT=''; DOMAIN=''; RECORDED_ENV=''; SEEN=' '
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in ''|'#'*) continue ;; ENVIRONMENT) key=RECORDED_ENV ;; INSTANCE_ID|HTTP_PORT|HTTPS_PORT|DOMAIN) ;; *) fail 'invalid instance.env field' ;; esac
  case "$SEEN" in *" $key "*) fail 'duplicate instance.env field' ;; esac
  SEEN="$SEEN$key "; printf -v "$key" '%s' "$value"
done < "$INPUT/instance.env"
[ "$RECORDED_ENV" = "$ENVIRONMENT" ] || fail 'explicit environment differs from instance'
[[ "$INSTANCE_ID" =~ ^[a-z][a-z0-9-]{5,47}$ ]] || fail 'invalid instance ID'
PROJECT="omega-$INSTANCE_ID"
TOKEN="$$-$(date +%s)"; TASK=''; CHILD=''; STAGE=preflight; MAINTENANCE=false; LOCKS=(); RUN_DIR=''
cleanup() {
  local code=$? lock
  trap - EXIT INT TERM
  [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null || true
  [ -z "$TASK" ] || docker rm -f "$TASK" >/dev/null 2>&1 || true
  if [ "$code" -ne 0 ] && [ "$MAINTENANCE" = true ]; then touch "$INPUT/edge/maintenance"; chmod 644 "$INPUT/edge/maintenance"; fi
  if [ -n "$RUN_DIR" ]; then
    printf '%s\texit=%s\tphase=%s\n' "$(date -u +%FT%TZ)" "$code" "$STAGE" >> "$RUN_DIR/journal.tsv"
    compose ps --all --format json > "$RUN_DIR/containers.json" 2>/dev/null || true
    for service in db api web console edge; do
      cid=$(compose ps --all -q "$service" 2>/dev/null) || continue
      [ -z "$cid" ] || docker inspect --format '{{.Name}} {{.Image}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" >> "$RUN_DIR/actual-images.txt" 2>/dev/null || true
    done
    compose logs --no-color --tail 100 > "$RUN_DIR/services.log" 2>&1 || true
  fi
  for lock in "${LOCKS[@]}"; do
    if [ -f "$lock/owner" ] && [ "$(cat "$lock/owner")" = "$TOKEN" ]; then rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true; fi
  done
  if [ "$code" -ne 0 ]; then echo "Release failed at $STAGE (exit $code). Maintenance=$MAINTENANCE; data retained. Evidence: $RUN_DIR" >&2; fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
acquire() { mkdir "$1" 2>/dev/null || { echo "operation lock held: $1" >&2; exit 6; }; LOCKS+=("$1"); printf '%s\n' "$TOKEN" > "$1/owner"; }
acquire "$INPUT/.lock"
LOCK_ROOT="/tmp/omega-locks-$(id -u)"; mkdir -p "$LOCK_ROOT"; chmod 700 "$LOCK_ROOT"; acquire "$LOCK_ROOT/$PROJECT"
run() {
  local limit=$1 start=$SECONDS result=0; shift
  "$@" & CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    if [ "$((SECONDS - start))" -ge "$limit" ]; then
      kill -TERM "$CHILD" 2>/dev/null || true; sleep 2; kill -KILL "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; CHILD=''; return 5
    fi
    sleep 1
  done
  wait "$CHILD" || result=$?; CHILD=''; return "$result"
}
tools() {
  TASK="$PROJECT-release-tools-$$"
  run 120 docker run --rm --pull never --platform linux/amd64 --name "$TASK" --network none --mount "type=bind,src=$INPUT,dst=/inputs" "$@" "$TOOLS_IMAGE" python /tools/inputs.py validate /inputs "$ENVIRONMENT"
  TASK=''
}
# All inherited Compose/OMEGA interpolation and .env sources are excluded.
CLEAN=(env -i "PATH=$PATH" "HOME=$HOME")
for key in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do value=$(printenv "$key" || true); [ -z "$value" ] || CLEAN+=("$key=$value"); done
VARS=("OMEGA_INPUT_DIR=$INPUT" "OMEGA_SOURCE_DIR=$MATERIALS" "OMEGA_INSTANCE_ID=$INSTANCE_ID" "OMEGA_ENVIRONMENT=$ENVIRONMENT" "OMEGA_HTTP_PORT=$HTTP_PORT" "OMEGA_HTTPS_PORT=$HTTPS_PORT" "OMEGA_DOMAIN=$DOMAIN" "OMEGA_VERSION=$VERSION" "OMEGA_UID=10001" "OMEGA_GID=10001")
for i in "${!IMAGE_ROLES[@]}"; do key=$(printf '%s' "${IMAGE_ROLES[$i]}" | tr '[:lower:]' '[:upper:]'); VARS+=("OMEGA_${key}_IMAGE=${IMAGE_IDS[$i]}"); done
COMPOSE=("${CLEAN[@]}" "${VARS[@]}" docker compose --project-name "$PROJECT" --project-directory "$MATERIALS" --env-file /dev/null -f "$MATERIALS/compose.yaml" -f "$MATERIALS/compose.release.yaml" -f "$MATERIALS/compose.$ENVIRONMENT.yaml")
compose() { "${COMPOSE[@]}" "$@"; }
oneoff() { TASK="$PROJECT-release-task-$$"; run 360 "${COMPOSE[@]}" run --rm --pull never --no-deps --name "$TASK" migrate --config /etc/omega/app.yaml --json "$@"; TASK=''; }
phase() { STAGE=$1; printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$STAGE" >> "$RUN_DIR/journal.tsv"; }
mkdir -p "$INPUT/.release/runs"
RUN_DIR="$INPUT/.release/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$"; mkdir "$RUN_DIR"
printf 'version=%s\ncommit=%s\nmanifest_sha256=%s\nenvironment=%s\ninstance=%s\ncommand=%s\n' "$VERSION" "$RELEASE_COMMIT" "$TRUSTED" "$ENVIRONMENT" "$INSTANCE_ID" "$COMMAND" > "$RUN_DIR/target.txt"
[ ! -f "$INPUT/.release/current" ] || cp "$INPUT/.release/current" "$RUN_DIR/previous-success.txt"
compose ps --all --format json > "$RUN_DIR/containers-before.json"
case "$COMMAND" in
  status) compose ps --all; printf 'Maintenance: '; if [ -f "$INPUT/edge/maintenance" ]; then echo active; else echo inactive; fi; [ ! -f "$INPUT/.release/current" ] || cat "$INPUT/.release/current"; df -h "$INPUT"; docker system df; curl --noproxy '*' --cacert "$INPUT/tls/cert.pem" --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" --max-time 10 --silent --show-error --fail "https://$DOMAIN:$HTTPS_PORT/api/v1/ping"; exit 0 ;;
  logs) compose logs --tail 200 --no-color; exit 0 ;;
  down) phase stop; run 120 "${COMPOSE[@]}" down --timeout 25; echo 'Stopped; persistent volumes retained'; exit 0 ;;
esac
phase inputs
tools
for label in "org.omega.instance=$INSTANCE_ID" "org.omega.environment=$ENVIRONMENT" "org.omega.input=$INPUT"; do
  if docker volume inspect "${PROJECT}_db_data" >/dev/null 2>&1; then
    [ "$(docker volume inspect --format "{{index .Labels \"${label%%=*}\"}}" "${PROJECT}_db_data")" = "${label#*=}" ] || fail 'database volume ownership mismatch'
  fi
done
TASK="$PROJECT-release-tools-$$"
run 120 docker run --rm --pull never --name "$TASK" --network none --mount "type=bind,src=$INPUT,dst=/inputs" "$TOOLS_IMAGE" python /tools/inputs.py render /inputs /inputs/edge "$ENVIRONMENT"
TASK=''
run 30 docker run --rm --pull never --network none --mount "type=bind,src=$INPUT,dst=/inputs,readonly" "$TOOLS_IMAGE" python /tools/release.py input-version /inputs "$VERSION"
compose config --format json > "$RUN_DIR/compose.json"
run 30 docker run --rm --pull never --network none --mount "type=bind,src=$RUN_DIR,dst=/evidence,readonly" "$TOOLS_IMAGE" python /tools/release.py model /evidence/compose.json
phase candidate-config
oneoff config validate > "$RUN_DIR/config.json"
if [ "$COMMAND" = tls-reload ]; then
  # Renewal applies only to the actual running set, never silently promotes it.
  for service in db api web console edge; do
    cid=$(compose ps -q "$service"); [ -n "$cid" ] || fail "TLS reload requires running service: $service"
    for i in "${!IMAGE_ROLES[@]}"; do
      [ "${IMAGE_ROLES[$i]}" != "$service" ] || [ "$(docker inspect --format '{{.Image}}' "$cid")" = "${IMAGE_IDS[$i]}" ] || fail 'TLS reload requires the current actual image set'
    done
  done
  touch "$INPUT/edge/maintenance"; chmod 644 "$INPUT/edge/maintenance"; MAINTENANCE=true
  phase tls-reload
  # Bind-mounted certificate/key inodes require a controlled edge recreation.
  run 120 "${COMPOSE[@]}" up -d --no-build --pull never --no-deps --force-recreate --wait --wait-timeout 90 edge
else
  phase database-preflight
  run 150 "${COMPOSE[@]}" up -d --no-build --pull never --wait --wait-timeout 120 db
  oneoff db status > "$RUN_DIR/db-before.json"
  if [ "$COMMAND" = rollback ]; then
    phase rollback-compatibility
    # Actual OLD binary checks current real schema, checksums and identity.
    oneoff doctor > "$RUN_DIR/rollback-compatibility.json"
  fi
  phase maintenance
  touch "$INPUT/edge/maintenance"; chmod 644 "$INPUT/edge/maintenance"; MAINTENANCE=true
  run 60 "${COMPOSE[@]}" stop --timeout 25 api web console
  if [ "$COMMAND" = deploy ]; then
    phase migration; oneoff db migrate > "$RUN_DIR/migration.json"
    phase metadata; oneoff data ensure > "$RUN_DIR/metadata.json"
  fi
  phase start
  run 270 "${COMPOSE[@]}" up -d --no-build --pull never --wait --wait-timeout 240 api web console edge
fi
phase image-verification
for service in db api web console edge; do
  cid=$(compose ps -q "$service"); [ -n "$cid" ] || fail "missing running service: $service"
  for i in "${!IMAGE_ROLES[@]}"; do
    [ "${IMAGE_ROLES[$i]}" != "$service" ] || [ "$(docker inspect --format '{{.Image}}' "$cid")" = "${IMAGE_IDS[$i]}" ] || fail "running image differs: $service"
  done
done
phase tls-smoke
EDGE=$(compose ps -q edge)
TASK="$PROJECT-release-smoke-$$"
run 120 docker run --rm --pull never --name "$TASK" --network "container:$EDGE" --mount "type=bind,src=$INPUT,dst=/inputs,readonly" "$TOOLS_IMAGE" python /tools/release.py smoke /inputs "$DOMAIN" "$VERSION" "$ENVIRONMENT"
TASK=''
if [ "$MAINTENANCE" = true ]; then
  code=$(curl --noproxy '*' --cacert "$INPUT/tls/cert.pem" --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" --max-time 10 --silent --show-error -o /dev/null -w '%{http_code}' "https://$DOMAIN:$HTTPS_PORT/api/v1/ping")
  [ "$code" = 503 ] || fail 'public maintenance gate did not return503'
fi
oneoff db status > "$RUN_DIR/db-after.json"
phase complete
printf 'version=%s\ncommit=%s\nmanifest_sha256=%s\nevidence=%s\n' "$VERSION" "$RELEASE_COMMIT" "$TRUSTED" "$RUN_DIR" > "$INPUT/.release/current.new"
mv "$INPUT/.release/current.new" "$INPUT/.release/current"
rm -f "$INPUT/edge/maintenance"; MAINTENANCE=false
echo "Release $VERSION ready: https://$DOMAIN:$HTTPS_PORT/web/ ($RUN_DIR)"
