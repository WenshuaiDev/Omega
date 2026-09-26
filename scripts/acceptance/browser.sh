#!/usr/bin/env bash
# A private committed source copy, a real dev stack, and a browser with no Docker socket.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
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
  [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null || true
  docker rm -f "$TASK" >/dev/null 2>&1 || true
  # Shell restoration also handles hard termination of the browser process.
  for file in App.tsx web.json console.json; do
    [ -f "$WORK/$file.original" ] || continue
    case "$file" in App.tsx) target="$SOURCE/packages/reference-app/src/App.tsx";; *) target="$INPUT/$file";; esac
    cp "$WORK/$file.original" "$target"
    cmp -s "$WORK/$file.original" "$target" || code=1
  done
  if [ -f "$INPUT/instance.env" ]; then
    PROJECT="omega-$(sed -n 's/^INSTANCE_ID=//p' "$INPUT/instance.env")"
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.ID}} {{.Names}} {{.Status}}' > "$OUTPUT/containers.txt"
    for service in api web console edge db; do
      cid=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$service")
      [ -z "$cid" ] || docker logs --tail 100 "$cid" > "$OUTPUT/$service.log" 2>&1 || true
    done
    # Only resources selected by this generated private instance's exact label.
    while IFS= read -r cid; do [ -z "$cid" ] || docker rm -f "$cid" >/dev/null || code=1; done < <(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
    while IFS= read -r volume; do [ -z "$volume" ] || docker volume rm "$volume" >/dev/null || code=1; done < <(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")
    while IFS= read -r network; do [ -z "$network" ] || docker network rm "$network" >/dev/null || code=1; done < <(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT")
    for image in api web console edge tools; do docker image rm "$PROJECT-$image:dev" >/dev/null 2>&1 || true; done
  fi
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf -- "$WORK"
  printf 'stage=%s\nexit=%s\nsource=%s\nnative_platform=separate-pending-20\n' "$STAGE" "$code" "$COMMIT" > "$OUTPUT/result.txt"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
run() {
  STAGE=$1; limit=$2; shift 2
  printf '%q ' "$@" > "$OUTPUT/$STAGE.argv"; printf '\n' >> "$OUTPUT/$STAGE.argv"
  echo "browser acceptance: $STAGE (evidence $OUTPUT)"
  "$@" > "$OUTPUT/$STAGE.log" 2>&1 & CHILD=$!
  started=$SECONDS; code=0
  while kill -0 "$CHILD" 2>/dev/null; do
    if [ "$((SECONDS-started))" -ge "$limit" ]; then
      kill -TERM "$CHILD" 2>/dev/null || true; sleep 1
      kill -KILL "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true
      CHILD=''; echo "$STAGE exceeded ${limit}s" >&2; return 5
    fi
    sleep 1
  done
  wait "$CHILD" || code=$?; CHILD=''
  [ "$code" = 0 ] || { cat "$OUTPUT/$STAGE.log" >&2; return "$code"; }
}
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
{
  printf 'source_commit=%s\n' "$COMMIT"
  uname -sm
  docker version --format 'client={{.Client.Version}}/{{.Client.Os}}/{{.Client.Arch}} server={{.Server.Version}}/{{.Server.Os}}/{{.Server.Arch}}'
  docker compose version
  echo 'Browser runs through Nginx in its network namespace; host published ingress is checked separately.'
  echo 'This suite alone does not complete native Linux amd64 acceptance #20.'
} > "$OUTPUT/platform.txt"
run browser-image 1800 docker build -f "$SOURCE/scripts/acceptance/Dockerfile" -t "$IMAGE" "$SOURCE"
docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$IMAGE" > "$OUTPUT/browser-image.txt"
run dev-start 2400 "$SOURCE/scripts/dev.sh" dev --input "$INPUT"
PROJECT="omega-$(sed -n 's/^INSTANCE_ID=//p' "$INPUT/instance.env")"
PORT=$(sed -n 's/^HTTP_PORT=//p' "$INPUT/instance.env")
EDGE=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=edge)
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
