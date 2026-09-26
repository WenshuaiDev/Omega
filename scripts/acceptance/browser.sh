#!/usr/bin/env bash
# A private committed source copy, a real dev stack, and a browser with no Docker socket.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/scripts/process.sh"
OUTPUT="$ROOT/artifacts/browser-$(date +%s)-$$"
while [ "$#" -gt 0 ]; do
  case "$1" in --output) [ "$#" -ge 2 ] || exit 2; OUTPUT=$2; shift 2;; *) echo 'usage: browser.sh [--output NEW_OR_EMPTY_DIRECTORY]' >&2; exit 2;; esac
done
for tool in docker git bash tar curl; do command -v "$tool" >/dev/null || { echo "missing prerequisite: $tool" >&2; exit 2; }; done
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo 'browser acceptance requires committed clean source' >&2; exit 2; }
[ ! -e "$OUTPUT" ] || { [ -d "$OUTPUT" ] && [ -z "$(ls -A "$OUTPUT")" ]; } || { echo 'evidence directory must be new or empty' >&2; exit 2; }
mkdir -p "$OUTPUT"; OUTPUT=$(cd "$OUTPUT" && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/omega browser acceptance.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
SOURCE="$WORK/source"; INPUT="$SOURCE/.omega/dev"
mkdir -p "$SOURCE"
git -C "$ROOT" archive HEAD | tar -xpf - -C "$SOURCE"
RUN="omega-browser-$(date +%s)-$$"; IMAGE="$RUN:acceptance"; TASK="$RUN-browser"
STAGE=setup; CHILD=''; PROJECT=''
cleanup() {
  local code=$?
  trap - EXIT INT TERM
  set +e
  printf 'stage=%s\nexit=%s\nsource=%s\ncleanup_complete=false\nnative_platform=separate-pending-20\n' "$STAGE" "$code" "${COMMIT:-unknown}" > "$OUTPUT/result.txt"
  # Let dev's trap stop its tracked Docker child and release locks before the
  # resource sweep or checkout removal. Forced termination retains the fixture.
  cleanup_ok=true
  [ "${STOP_FORCED:-false}" = false ] || cleanup_ok=false
  stop_child "$CHILD" 20; CHILD=''
  [ "${STOP_FORCED:-false}" = false ] || cleanup_ok=false
  if ! bounded 3 docker info >/dev/null 2>&1; then
    cleanup_ok=false
    [ "$code" -ne 0 ] || code=5
  fi
  if [ "$cleanup_ok" = true ]; then bounded 5 docker rm -f "$TASK" >/dev/null 2>&1 || true; fi
  # Record cancellation/failure even if this wrapper is itself killed while
  # attempting best-effort cleanup. The final record below refines this state.
  printf 'stage=%s\nexit=%s\nsource=%s\ncleanup_complete=false\nnative_platform=separate-pending-20\n' "$STAGE" "$code" "${COMMIT:-unknown}" > "$OUTPUT/result.txt"
  # Shell restoration also handles hard termination of the browser process.
  for file in App.tsx web.json console.json; do
    [ -f "$WORK/$file.original" ] || continue
    case "$file" in App.tsx) target="$SOURCE/packages/reference-app/src/App.tsx";; *) target="$INPUT/$file";; esac
    cp "$WORK/$file.original" "$target"
    cmp -s "$WORK/$file.original" "$target" || code=1
  done
  cleanup_started=$SECONDS
  cleanup_docker() {
    [ "$((SECONDS-cleanup_started))" -lt 25 ] || return 5
    bounded 3 docker "$@"
  }
  if [ "$cleanup_ok" = true ] && [ -f "$INPUT/instance.env" ]; then
    PROJECT="omega-$(sed -n 's/^INSTANCE_ID=//p' "$INPUT/instance.env")"
    cleanup_docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.ID}} {{.Names}} {{.Status}}' > "$OUTPUT/containers.txt" || cleanup_ok=false
    for service in api web console edge db; do
      cid=$(cleanup_docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$service") || { cleanup_ok=false; break; }
      [ -z "$cid" ] || cleanup_docker logs --tail 100 "$cid" > "$OUTPUT/$service.log" 2>&1 || true
    done
    # Explicit query status prevents an unavailable daemon from looking like an
    # empty resource set. Retain the checkout whenever cleanup is incomplete.
    ids=$(cleanup_docker ps -aq --filter "label=com.docker.compose.project=$PROJECT") || cleanup_ok=false
    for cid in $ids; do cleanup_docker rm -f "$cid" >/dev/null || cleanup_ok=false; done
    ids=$(cleanup_docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT") || cleanup_ok=false
    for volume in $ids; do cleanup_docker volume rm "$volume" >/dev/null || cleanup_ok=false; done
    ids=$(cleanup_docker network ls -q --filter "label=com.docker.compose.project=$PROJECT") || cleanup_ok=false
    for network in $ids; do cleanup_docker network rm "$network" >/dev/null || cleanup_ok=false; done
    for image in api web console edge tools; do cleanup_docker image rm "$PROJECT-$image:dev" >/dev/null 2>&1 || true; done
  fi
  if [ "$cleanup_ok" = true ]; then cleanup_docker image rm "$IMAGE" >/dev/null 2>&1 || true
    rm -rf -- "$WORK"
  else
    printf 'Cleanup incomplete; owned private fixture retained at %s\n' "$WORK" > "$OUTPUT/cleanup.txt"
  fi
  [ "$cleanup_ok" = true ] || { [ "$code" -ne 0 ] || code=5; }
  printf 'stage=%s\nexit=%s\nsource=%s\ncleanup_complete=%s\nnative_platform=separate-pending-20\n' "$STAGE" "$code" "$COMMIT" "$cleanup_ok" > "$OUTPUT/result.txt"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
run() {
  STAGE=$1; limit=$2; shift 2
  printf '%q ' "$@" > "$OUTPUT/$STAGE.argv"; printf '\n' >> "$OUTPUT/$STAGE.argv"
  echo "browser acceptance: $STAGE (evidence $OUTPUT)"
  local code=0 BOUND_GRACE=20
  bounded "$limit" "$@" > "$OUTPUT/$STAGE.log" 2>&1 || code=$?
  [ "$code" = 0 ] || { cat "$OUTPUT/$STAGE.log" >&2; return "$code"; }
}
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
{
  printf 'source_commit=%s\n' "$COMMIT"
  uname -sm
  bounded 15 docker version --format 'client={{.Client.Version}}/{{.Client.Os}}/{{.Client.Arch}} server={{.Server.Version}}/{{.Server.Os}}/{{.Server.Arch}}'
  bounded 10 docker compose version
  echo 'Browser runs through Nginx in its network namespace; host published ingress is checked separately.'
  echo 'This suite alone does not complete native Linux amd64 acceptance #20.'
} > "$OUTPUT/platform.txt"
run browser-image 1800 docker build -f "$SOURCE/scripts/acceptance/Dockerfile" -t "$IMAGE" "$SOURCE"
bounded 10 docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$IMAGE" > "$OUTPUT/browser-image.txt"
run dev-start 2400 "$SOURCE/scripts/dev.sh" dev --input "$INPUT"
PROJECT="omega-$(sed -n 's/^INSTANCE_ID=//p' "$INPUT/instance.env")"
PORT=$(sed -n 's/^HTTP_PORT=//p' "$INPUT/instance.env")
EDGE=$(bounded 10 docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=edge)
[ -n "$EDGE" ] || { echo 'owned edge container not found' >&2; exit 1; }
run published-ingress 15 curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$PORT/api/v1/ping"
cp "$SOURCE/packages/reference-app/src/App.tsx" "$WORK/App.tsx.original"
cp "$INPUT/web.json" "$WORK/web.json.original"
cp "$INPUT/console.json" "$WORK/console.json.original"
run browser-scenarios 300 docker run --rm --pull never --name "$TASK" --init \
  --network "container:$EDGE" --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
  --shm-size 1g -e HOME=/tmp \
  --mount "type=bind,src=$SOURCE/packages/reference-app/src/App.tsx,dst=/fixtures/App.tsx" \
  --mount "type=bind,src=$INPUT/web.json,dst=/fixtures/web.json" \
  --mount "type=bind,src=$INPUT/console.json,dst=/fixtures/console.json" \
  --mount "type=bind,src=$OUTPUT,dst=/evidence" "$IMAGE"
for file in App.tsx web.json console.json; do
  case "$file" in App.tsx) target="$SOURCE/packages/reference-app/src/App.tsx";; *) target="$INPUT/$file";; esac
  cmp -s "$WORK/$file.original" "$target" || { echo "fixture was not restored: $file" >&2; exit 1; }
done
STAGE=complete
echo "Browser scenarios passed; evidence: $OUTPUT"
