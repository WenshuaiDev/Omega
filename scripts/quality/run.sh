#!/usr/bin/env bash
# Disposable source snapshot and resources; no host language runtimes required.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODE=$1; shift
OUTPUT=''
PLATFORM=linux/amd64
TIMEOUT=1800
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|--platform|--timeout)
      [ "$#" -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }
      case "$1" in --output) OUTPUT=$2 ;; --platform) PLATFORM=$2 ;; --timeout) TIMEOUT=$2 ;; esac
      shift 2 ;;
    --help)
      echo "Usage: scripts/$MODE.sh [--output DIRECTORY] [--platform linux/amd64] [--timeout SECONDS]"
      echo 'check: format, static/type checks, immutable dependencies, tests, three Compose models, production image builds.'
      echo 'test: all workspace tests, including real isolated PostgreSQL CLI/API processes.'
      echo 'Both snapshot current nonignored source; no user instance or host runtime is used.'
      echo 'Production builds target linux/amd64. --timeout bounds each stage (default 1800).'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$PLATFORM" = linux/amd64 ] || { echo 'formal build platform must be linux/amd64' >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo 'timeout must be a positive integer' >&2; exit 2; }
for utility in docker git mktemp cat; do command -v "$utility" >/dev/null || { echo "missing prerequisite: $utility" >&2; exit 2; }; done
docker info >/dev/null 2>&1 || { echo 'Docker daemon unavailable' >&2; exit 2; }
docker compose version >/dev/null
RUN="omega-quality-$(date +%s)-$$"
if [ -z "$OUTPUT" ]; then OUTPUT="$ROOT/artifacts/$RUN"; fi
mkdir -p -- "$OUTPUT"
OUTPUT=$(cd -- "$OUTPUT" && pwd -P)
case "$ROOT$OUTPUT" in *','*|*$'\n'*) echo 'Docker bind paths cannot contain commas/newlines' >&2; exit 2 ;; esac
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/$RUN.XXXXXX")
NETWORK="$RUN"; VOLUME="$RUN-source"; TASK="$RUN-task"; DB="$RUN-db"
TOOLS="$RUN-tools:check"; GO="$RUN-go:check"; NODE="$RUN-node:check"
IMAGES=("$TOOLS" "$GO" "$NODE")
STAGE=preflight; CHILD=''
cleanup() {
  result=$?
  trap - EXIT INT TERM
  [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null || true
  docker rm -f "$TASK" "$DB" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  docker image rm "${IMAGES[@]}" >/dev/null 2>&1 || true
  rm -rf -- "$TEMP"
  printf 'mode=%s\nstage=%s\nexit=%s\nfinished=%s\n' "$MODE" "$STAGE" "$result" "$(date -u +%FT%TZ)" > "$OUTPUT/result.txt"
  if [ "$result" = 0 ]; then echo "Omega $MODE passed. Evidence: $OUTPUT"; else echo "Omega $MODE failed at $STAGE (exit $result). Evidence: $OUTPUT" >&2; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
run() {
  STAGE=$1; shift
  printf '\n== %s ==\n' "$STAGE"
  "$@" > "$OUTPUT/$STAGE.log" 2>&1 & CHILD=$!
  started=$SECONDS; result=0
  while kill -0 "$CHILD" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge "$TIMEOUT" ]; then
      kill -TERM "$CHILD" 2>/dev/null || true
      for ((grace=0; grace<5; grace++)); do
        kill -0 "$CHILD" 2>/dev/null || break
        sleep 1
      done
      kill -KILL "$CHILD" 2>/dev/null || true
      wait "$CHILD" 2>/dev/null || true
      CHILD=''
      cat "$OUTPUT/$STAGE.log"
      echo "stage exceeded ${TIMEOUT}s timeout" >&2
      return 5
    fi
    sleep 1
  done
  wait "$CHILD" || result=$?
  CHILD=''
  cat "$OUTPUT/$STAGE.log"
  [ "$result" = 0 ] || return "$result"
}
{
  date -u +%FT%TZ
  git -C "$ROOT" rev-parse HEAD
  git -C "$ROOT" status --short
  uname -sm
  docker version --format 'client={{.Client.Version}}/{{.Client.Os}}/{{.Client.Arch}} server={{.Server.Version}}/{{.Server.Os}}/{{.Server.Arch}}'
  docker compose version
  printf 'formal image target=%s; cross-build is not native-platform acceptance\n' "$PLATFORM"
} > "$OUTPUT/environment.txt"
# Track dirty/untracked current code too, but never Git-ignored credentials/caches.
git -C "$ROOT" ls-files --cached --others --exclude-standard -z > "$TEMP/source-files"
while IFS= read -r -d '' source_file; do
  case "$source_file" in *.sh) [ ! -f "$ROOT/$source_file" ] || bash -n "$ROOT/$source_file" ;; esac
done < "$TEMP/source-files"
run tools-image docker build -f "$ROOT/infra/tools/Dockerfile" -t "$TOOLS" "$ROOT"
run go-image docker build --target development -f "$ROOT/services/api/Dockerfile" -t "$GO" "$ROOT"
run node-image docker build --target development -f "$ROOT/apps/Dockerfile" -t "$NODE" "$ROOT"
docker volume create --label "org.omega.quality=$RUN" "$VOLUME" >/dev/null
COMMON=(--rm --name "$TASK" --user "$(id -u):$(id -g)" --mount "type=volume,src=$VOLUME,dst=/workspace" --workdir /workspace -e HOME=/tmp)
run snapshot docker run --rm --name "$TASK" --network none \
  --mount "type=bind,src=$ROOT,dst=/source,readonly" \
  --mount "type=bind,src=$TEMP,dst=/plan,readonly" \
  --mount "type=volume,src=$VOLUME,dst=/workspace" "$TOOLS" \
  python /source/scripts/quality/model_check.py snapshot /source /plan/source-files /workspace "$(id -u)" "$(id -g)"
run tools-versions docker run "${COMMON[@]}" --network none "$TOOLS" python scripts/quality/model_check.py toolchain
docker network create --label "org.omega.quality=$RUN" "$NETWORK" >/dev/null
# Database tests use only this disposable instance, never the developer database.
DB_IMAGE=$(docker run "${COMMON[@]}" --network none "$TOOLS" python scripts/quality/model_check.py db-image)
run postgres docker run -d --name "$DB" --network "$NETWORK" --network-alias db \
  --label "org.omega.quality=$RUN" --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_DB=omega -e POSTGRES_PASSWORD=admin-secret "$DB_IMAGE"
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if docker exec "$DB" pg_isready -U postgres >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[ "$ready" = true ] || { echo 'isolated PostgreSQL startup timeout' >&2; exit 5; }
run go-$MODE docker run "${COMMON[@]}" --network "$NETWORK" \
  -e GOPATH=/workspace/.quality-go -e GOCACHE=/workspace/.quality-go/cache \
  -e GOFLAGS=-mod=readonly -e GOTOOLCHAIN=local \
  -e 'OMEGA_TEST_ADMIN_DSN=postgres://postgres:admin-secret@db:5432/omega?sslmode=disable' \
  "$GO" go run scripts/quality/go_check.go "$MODE"
run frontend-$MODE docker run "${COMMON[@]}" --network "$NETWORK" "$NODE" node scripts/quality/frontend.mjs "$MODE"
run checker-tests docker run "${COMMON[@]}" --network none "$TOOLS" python -m unittest discover -s scripts/quality -p '*_test.py' -v
if [ "$MODE" = check ]; then
  CLEAN_ENV=(env -i "PATH=$PATH" "HOME=$HOME")
  for name in DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
    value=$(printenv "$name" || true); [ -z "$value" ] || CLEAN_ENV+=("$name=$value")
  done
  for environment in dev test prod; do
    FILES=(-f "$ROOT/compose.yaml")
    if [ "$environment" = dev ]; then FILES+=(-f "$ROOT/compose.dev.yaml"); else FILES+=(-f "$ROOT/compose.release.yaml" -f "$ROOT/compose.$environment.yaml"); fi
    "${CLEAN_ENV[@]}" OMEGA_INPUT_DIR=/quality-input OMEGA_SOURCE_DIR=/quality-source \
      OMEGA_INSTANCE_ID=quality-instance "OMEGA_ENVIRONMENT=$environment" OMEGA_HTTP_PORT=18080 OMEGA_HTTPS_PORT=18443 \
      OMEGA_DOMAIN=omega.test OMEGA_UID=1000 OMEGA_GID=1000 OMEGA_VERSION=quality \
      OMEGA_API_IMAGE=omega-api:quality OMEGA_WEB_IMAGE=omega-web:quality OMEGA_CONSOLE_IMAGE=omega-console:quality \
      OMEGA_EDGE_IMAGE=omega-edge:quality OMEGA_TOOLS_IMAGE=omega-tools:quality "OMEGA_DB_IMAGE=$DB_IMAGE" \
      docker compose --profile '*' --project-name "$RUN" --project-directory "$ROOT" --env-file /dev/null "${FILES[@]}" config --format json > "$OUTPUT/compose-$environment.json"
    run "compose-$environment" docker run "${COMMON[@]}" --network none \
      --mount "type=bind,src=$OUTPUT,dst=/reports,readonly" "$TOOLS" \
      python scripts/quality/model_check.py model "$environment" "/reports/compose-$environment.json"
  done
  docker run "${COMMON[@]}" --network none "$TOOLS" python scripts/quality/model_check.py images > "$TEMP/images"
  COMMIT=$(git -C "$ROOT" rev-parse HEAD)
  while IFS='|' read -r key dockerfile target app; do
    [ -n "$key" ] || continue
    tag="$RUN-$key:production"; IMAGES+=("$tag")
    BUILD=(--platform "$PLATFORM" -f "$ROOT/$dockerfile" --build-arg VERSION=quality --build-arg "COMMIT=$COMMIT" -t "$tag")
    [ -z "$target" ] || BUILD+=(--target "$target")
    [ -z "$app" ] || BUILD+=(--build-arg "APP=$app")
    run "build-$key" docker build "${BUILD[@]}" "$ROOT"
    [ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$tag")" = quality ] || { echo 'wrong production version label' >&2; exit 3; }
    [ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$tag")" = "$COMMIT" ] || { echo 'wrong production commit label' >&2; exit 3; }
    printf 'omega-%s:quality\t%s\n' "$key" "$(docker image inspect --format '{{.Config.User}}' "$tag")" >> "$OUTPUT/image-users.tsv"
    docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}} {{json .Config.Labels}}' "$tag" >> "$OUTPUT/production-images.txt"
    [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$tag")" = "$PLATFORM" ] || { echo 'wrong production image platform' >&2; exit 3; }
    if [ "$key" = api ]; then
      run binary-versions docker run --rm --name "$TASK" --network none --platform "$PLATFORM" --entrypoint omega "$tag" --json version
      [ "$(docker run --rm --network none --platform "$PLATFORM" "$tag" --version)" = "quality $COMMIT" ] || { echo 'API binary version differs from release labels' >&2; exit 3; }
      run cli-version-check docker run "${COMMON[@]}" --network none --mount "type=bind,src=$OUTPUT,dst=/reports,readonly" "$TOOLS" python scripts/quality/model_check.py cli-version /reports/binary-versions.log "$COMMIT"
    fi
  done < "$TEMP/images"
  run inherited-image-users docker run "${COMMON[@]}" --network none --mount "type=bind,src=$OUTPUT,dst=/reports,readonly" "$TOOLS" python scripts/quality/model_check.py image-users /reports
fi
run unchanged-dependencies docker run "${COMMON[@]}" --network none --mount "type=bind,src=$ROOT,dst=/source,readonly" "$TOOLS" python scripts/quality/model_check.py unchanged
STAGE=complete
