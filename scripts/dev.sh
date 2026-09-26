#!/usr/bin/env bash
# Thin host orchestration: Bash, Docker/Compose, curl and standard Unix utilities only.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
COMMAND=${1:-dev}
if [ "$#" -gt 0 ]; then shift; fi
INPUT="$ROOT/.omega/dev"
CONFIRM=''
OMEGA_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; OMEGA_ARGS=("$@"); break ;;
    --input) [ "$#" -ge 2 ] || { echo '--input requires a directory' >&2; exit 2; }; INPUT=$2; shift 2 ;;
    --confirm) [ "$#" -ge 2 ] || { echo '--confirm requires the exact instance ID' >&2; exit 2; }; CONFIRM=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$COMMAND" in dev|down|status|logs|dev-reset|omega) ;; *) echo 'expected dev, down, status, logs, or dev-reset' >&2; exit 2 ;; esac
for utility in docker curl git make od awk sed cksum; do
  command -v "$utility" >/dev/null || { echo "missing prerequisite: $utility" >&2; exit 2; }
done
docker info >/dev/null 2>&1 || { echo 'Docker daemon is unavailable; start Docker or select the intended context.' >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo 'Docker Compose plugin is required.' >&2; exit 2; }
if [ "$COMMAND" = dev ]; then mkdir -p -- "$INPUT"; fi
[ -d "$INPUT" ] || { echo "instance input does not exist: $INPUT" >&2; exit 2; }
INPUT=$(cd -- "$INPUT" && pwd -P)
case "$INPUT" in *$'\n'*|*','*) echo 'input paths containing newlines or commas are not supported by Docker mount syntax' >&2; exit 2 ;; esac
chmod 700 "$INPUT"
STAGE=preflight
TASK=''
CHILD=''
LOCKS=()
TOKEN="$$-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null || true
  if [ -n "$TASK" ]; then docker rm -f "$TASK" >/dev/null 2>&1 || true; fi
  local lock
  for lock in "${LOCKS[@]-}"; do
    [ -n "$lock" ] || continue
    if [ -f "$lock/owner" ] && [ "$(cat "$lock/owner")" = "$TOKEN" ]; then rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true; fi
  done
  if [ "$result" -ne 0 ]; then echo "omega: $STAGE failed (exit $result); data and diagnostics retained. Input: $INPUT" >&2; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
acquire() {
  local lock=$1
  if ! mkdir "$lock" 2>/dev/null; then
    echo "operation lock held: $lock. If its process is no longer running, inspect owner and remove only this stale lock." >&2
    exit 6
  fi
  LOCKS+=("$lock")
  printf '%s\n' "$TOKEN" > "$lock/owner"
}
# Read-only commands never mutate instance state, but also avoid transient preparation output.
acquire "$INPUT/.lock"
run() {
  local seconds=$1; shift
  local started=$SECONDS result=0
  "$@" & CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge "$seconds" ]; then
      kill -TERM "$CHILD" 2>/dev/null || true
      local grace=0
      while kill -0 "$CHILD" 2>/dev/null && [ "$grace" -lt 5 ]; do sleep 1; grace=$((grace + 1)); done
      kill -KILL "$CHILD" 2>/dev/null || true
      wait "$CHILD" 2>/dev/null || true
      CHILD=''
      echo "operation exceeded ${seconds}s timeout" >&2
      return 5
    fi
    sleep 1
  done
  wait "$CHILD" || result=$?
  CHILD=''
  return "$result"
}

if [ ! -f "$INPUT/instance.env" ]; then
  [ "$COMMAND" = dev ] || { echo 'missing instance.env' >&2; exit 2; }
  if [ -n "$(docker volume ls -q --filter "label=org.omega.input=$INPUT")" ]; then
    echo 'Persistent volume exists but instance.env is missing; restore the original inputs. No replacement identity will be generated.' >&2
    exit 3
  fi
  INSTANCE_ID="dev-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  PORT_HASH=$(printf '%s' "$INPUT" | cksum | awk '{print $1}')
  HTTP_PORT=$((20000 + PORT_HASH % 30000))
  printf 'ENVIRONMENT=dev\nINSTANCE_ID=%s\nHTTP_PORT=%s\nHTTPS_PORT=%s\nDOMAIN=localhost\n' "$INSTANCE_ID" "$HTTP_PORT" "$((HTTP_PORT + 1))" > "$INPUT/instance.env"
fi
ENVIRONMENT=''; INSTANCE_ID=''; HTTP_PORT=''; HTTPS_PORT=''; DOMAIN=''
SEEN=' '
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in ''|'#'*) continue ;; ENVIRONMENT|INSTANCE_ID|HTTP_PORT|HTTPS_PORT|DOMAIN) ;; *) echo 'invalid instance.env field' >&2; exit 2 ;; esac
  case "$SEEN" in *" $key "*) echo 'duplicate instance.env field' >&2; exit 2 ;; esac
  SEEN="$SEEN$key "
  # printf -v assigns data without evaluating shell input.
  printf -v "$key" '%s' "$value"
done < "$INPUT/instance.env"
[ "$ENVIRONMENT" = dev ] || { echo 'development commands require an explicit dev instance; test/prod targets are refused' >&2; exit 3; }
[[ "$INSTANCE_ID" =~ ^[a-z][a-z0-9-]{5,47}$ ]] || { echo 'invalid instance ID' >&2; exit 2; }
for port in "$HTTP_PORT" "$HTTPS_PORT"; do
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || { echo 'invalid instance port' >&2; exit 2; }
done
[[ "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'invalid domain' >&2; exit 2; }
PROJECT="omega-$INSTANCE_ID"
LOCK_ROOT="${TMPDIR:-/tmp}/omega-locks-$(id -u)"
mkdir -p "$LOCK_ROOT"; chmod 700 "$LOCK_ROOT"
acquire "$LOCK_ROOT/$PROJECT"
DB_VOLUME="${PROJECT}_db_data"
HAS_DB=false
if docker volume inspect "$DB_VOLUME" >/dev/null 2>&1; then
  HAS_DB=true
  for pair in "org.omega.instance=$INSTANCE_ID" "org.omega.environment=dev" "org.omega.input=$INPUT"; do
    label=${pair%%=*}; expected=${pair#*=}
    actual=$(docker volume inspect --format "{{index .Labels \"$label\"}}" "$DB_VOLUME")
    [ "$actual" = "$expected" ] || { echo 'database volume ownership differs from requested instance/input; refusing' >&2; exit 3; }
  done
  for role in admin migrator runtime; do
    [ -s "$INPUT/secrets/$role" ] || { echo "database volume exists but original $role credential is missing; restore original credentials" >&2; exit 3; }
  done
fi
HOST_UID=$(id -u); HOST_GID=$(id -g)
TOOLS_IMAGE="$PROJECT-tools:dev"
API_IMAGE="$PROJECT-api:dev"
WEB_IMAGE="$PROJECT-web:dev"
CONSOLE_IMAGE="$PROJECT-console:dev"
EDGE_IMAGE="$PROJECT-edge:dev"
# Compose interpolation cannot see inherited COMPOSE_* or OMEGA_* values, nor .env.
CLEAN_ENV=(env -i "PATH=$PATH" "HOME=$HOME")
for name in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
  value=$(printenv "$name" || true)
  [ -z "$value" ] || CLEAN_ENV+=("$name=$value")
done
COMPOSE=("${CLEAN_ENV[@]}" "OMEGA_INPUT_DIR=$INPUT" "OMEGA_SOURCE_DIR=$ROOT" "OMEGA_INSTANCE_ID=$INSTANCE_ID" "OMEGA_ENVIRONMENT=dev" "OMEGA_HTTP_PORT=$HTTP_PORT" "OMEGA_HTTPS_PORT=$HTTPS_PORT" "OMEGA_DOMAIN=$DOMAIN" "OMEGA_UID=$HOST_UID" "OMEGA_GID=$HOST_GID" "OMEGA_VERSION=dev" "OMEGA_API_IMAGE=$API_IMAGE" "OMEGA_WEB_IMAGE=$WEB_IMAGE" "OMEGA_CONSOLE_IMAGE=$CONSOLE_IMAGE" "OMEGA_EDGE_IMAGE=$EDGE_IMAGE" "OMEGA_DB_IMAGE=postgres:17.10-alpine" docker compose --project-name "$PROJECT" --project-directory "$ROOT" --env-file /dev/null -f "$ROOT/compose.yaml" -f "$ROOT/compose.dev.yaml")
compose() { "${COMPOSE[@]}" "$@"; }
oneoff() {
  TASK="$PROJECT-task-$$"
  run 900 "${COMPOSE[@]}" run --rm --no-deps --name "$TASK" "$@"
  TASK=''
}
tools() {
  TASK="$PROJECT-tools-$$"
  run 300 docker run --rm --name "$TASK" --network none --mount "type=bind,src=$INPUT,dst=/inputs" "$@"
  TASK=''
}
case "$COMMAND" in
  omega)
    STAGE=maintenance
    [ "${#OMEGA_ARGS[@]}" -gt 0 ] || OMEGA_ARGS=(--help)
    operation=''
    for arg in "${OMEGA_ARGS[@]}"; do
      case "$arg" in --config|--config=*) echo 'select config through --input, not --config' >&2; exit 2 ;; --json) ;; *) operation="${operation}${operation:+ }$arg" ;; esac
    done
    case "$operation" in
      'health check')
        run 300 "${COMPOSE[@]}" exec -T api sh -c 'go build -o /tmp/omega-health ./services/api/cmd/omega && exec /tmp/omega-health --config /etc/omega/app.yaml "$@"' omega "${OMEGA_ARGS[@]}" ;;
      'db migrate'|'data ensure')
        run 60 "${COMPOSE[@]}" stop --timeout 25 api
        oneoff migrate --config /etc/omega/app.yaml "${OMEGA_ARGS[@]}"
        run 240 "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 210 api ;;
      *) oneoff migrate --config /etc/omega/app.yaml "${OMEGA_ARGS[@]}" ;;
    esac ;;
  down)
    STAGE=stop; run 120 "${COMPOSE[@]}" down --timeout 25
    echo "Stopped $PROJECT; persistent volumes retained." ;;
  status)
    compose ps --all
    printf '\nInstance: %s\nEntry: http://localhost:%s/web/\n' "$INSTANCE_ID" "$HTTP_PORT"
    df -h "$INPUT"
    docker system df
    curl --max-time 5 --fail --silent --show-error "http://127.0.0.1:$HTTP_PORT/api/v1/ping" || true
    printf '\n' ;;
  logs)
    compose logs --tail 200 --no-color ;;
  dev-reset)
    STAGE=reset
    printf 'DESTRUCTIVE dev reset\nInstance: %s\nInputs: %s\nProject: %s\nVolumes:\n' "$INSTANCE_ID" "$INPUT" "$PROJECT"
    docker volume ls --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Name}}'
    if [ -z "$CONFIRM" ]; then
      [ -t 0 ] || { echo 'noninteractive reset requires --confirm EXACT_INSTANCE_ID' >&2; exit 3; }
      read -r -p "Type $INSTANCE_ID to delete this dev instance data: " CONFIRM
    fi
    [ "$CONFIRM" = "$INSTANCE_ID" ] || { echo 'confirmation did not match instance ID' >&2; exit 3; }
    # Validate recorded database identity before destructive action whenever a DB exists.
    if [ "$HAS_DB" = true ]; then
      run 120 "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 90 db
      oneoff migrate --config /etc/omega/app.yaml doctor
    fi
    run 120 "${COMPOSE[@]}" down --volumes --timeout 25
    echo 'Selected dev data deleted; existing inputs and credentials retained.' ;;
  dev)
    STAGE=tools-image
    run 900 docker build -f "$ROOT/infra/tools/Dockerfile" -t "$TOOLS_IMAGE" "$ROOT"
    STAGE=prepare-inputs
    tools --user "$HOST_UID:$HOST_GID" "$TOOLS_IMAGE" python /tools/inputs.py init /inputs dev
    tools --user "$HOST_UID:$HOST_GID" "$TOOLS_IMAGE" python /tools/inputs.py validate /inputs dev
    tools "$TOOLS_IMAGE" python /tools/inputs.py render /inputs /inputs/edge dev "$HOST_UID" "$HOST_GID"
    STAGE=compose-model
    compose config --quiet
    STAGE=development-images
    run 1800 "${COMPOSE[@]}" build api web console edge
    # Create mountpoints as the developer, not as Docker root.
    mkdir -p "$ROOT/node_modules" "$ROOT/.yarn" "$ROOT/apps/web/node_modules" "$ROOT/apps/console/node_modules" "$ROOT/packages/reference-app/node_modules"
    STAGE=database
    run 120 "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 90 db
    STAGE=coordinate-applications
    run 60 "${COMPOSE[@]}" stop --timeout 25 api web console
    STAGE=writable-dependency-volumes
    # Explicit one-off root task adjusts only named cache volumes, never source.
    TASK="$PROJECT-cache-$$"
    CACHE_ARGS=()
    for volume in go_cache node_modules yarn_cache web_node_modules console_node_modules shared_node_modules; do
      docker volume create --label "com.docker.compose.project=$PROJECT" --label "com.docker.compose.volume=$volume" "${PROJECT}_$volume" >/dev/null
      CACHE_ARGS+=(--mount "type=volume,src=${PROJECT}_$volume,dst=/cache/$volume")
    done
    run 120 docker run --rm --name "$TASK" --user 0:0 --network none "${CACHE_ARGS[@]}" --entrypoint sh "$WEB_IMAGE" -c 'chown -R "$1:$2" /cache' sh "$HOST_UID" "$HOST_GID"
    TASK=''
    STAGE=immutable-dependencies
    oneoff deps
    STAGE=application-config
    oneoff migrate --config /etc/omega/app.yaml config validate
    STAGE=migration
    oneoff migrate --config /etc/omega/app.yaml db migrate
    STAGE=system-metadata
    oneoff migrate --config /etc/omega/app.yaml data ensure
    STAGE=long-running-services
    run 240 "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 210 api web console edge
    STAGE=external-smoke
    for path in /web/ /console/ /web/runtime-config.json /console/runtime-config.json /api/v1/ping; do
      run 40 curl --retry 8 --retry-all-errors --retry-delay 1 --max-time 3 --fail --silent --show-error "http://127.0.0.1:$HTTP_PORT$path" -o /dev/null
    done
    printf '\nOmega dev ready (%s)\n  http://localhost:%s/web/\n  http://localhost:%s/console/\n' "$INSTANCE_ID" "$HTTP_PORT" "$HTTP_PORT" ;;
esac
