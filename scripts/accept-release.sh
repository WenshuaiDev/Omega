#!/usr/bin/env bash
# Explicit isolated offline drill. No host socket, networking change or prune.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/release-common.sh"
[ "$#" = 10 ] || fail 'usage: accept-release.sh ARCHIVE ARCHIVE_SHA VERSION MANIFEST_SHA HARNESS_IMAGE NEW_EVIDENCE_DIR [OLD_ARCHIVE OLD_ARCHIVE_SHA OLD_VERSION OLD_MANIFEST_SHA]'
ARCHIVE=$1; ARCHIVE_SHA=$2; VERSION=$3; MANIFEST_SHA=$4; HARNESS=$5; EVIDENCE=$6
OLD_ARCHIVE=$7; OLD_SHA=$8; OLD_VERSION=$9; OLD_MANIFEST=${10}
[ -f "$OLD_ARCHIVE" ] && [ -n "$OLD_SHA" ] && [ -n "$OLD_VERSION" ] && [ -n "$OLD_MANIFEST" ] || fail 'actual rollback requires a complete old candidate'
[ "$OLD_VERSION" != "$VERSION" ] && [ "$OLD_SHA" != "$ARCHIVE_SHA" ] && [ "$OLD_MANIFEST" != "$MANIFEST_SHA" ] || fail 'rollback candidate must have a distinct version, archive and manifest'
[ ! -e "$EVIDENCE" ] || fail 'use a new evidence directory'
prerequisites
docker image inspect --platform linux/amd64 "$HARNESS" >/dev/null || fail 'prebuild the acceptance harness online first'
mkdir -p "$EVIDENCE/operator/scripts"
EVIDENCE=$(cd "$EVIDENCE" && pwd -P)
ARCHIVE=$(cd "$(dirname "$ARCHIVE")" && pwd -P)/$(basename "$ARCHIVE")
cp "$ROOT/scripts/"{import-release,release-common,process}.sh "$EVIDENCE/operator/scripts/"
cp "$ROOT/scripts/accept-release-target.sh" "$EVIDENCE/operator/target.sh"
cp "$ROOT/infra/acceptance/scan_secrets.py" "$EVIDENCE/operator/scan_secrets.py"
RUN="omega-offline-$(date +%s)-$$"; DATA="$RUN-data"; CHILD=''
cleanup() {
  local code=$?
  trap - EXIT INT TERM
  [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null || true
  bounded 20 docker logs "$RUN" > "$EVIDENCE/daemon.log" 2>&1 || true
  bounded 20 docker cp "$RUN:/evidence/." "$EVIDENCE/" >/dev/null 2>&1 || true
  if [ "$code" = 0 ]; then
    bounded 30 docker rm -f "$RUN" >/dev/null 2>&1 || true
    bounded 20 docker volume rm "$DATA" >/dev/null
  else
    bounded 30 docker stop --time 15 "$RUN" >/dev/null 2>&1 || true
    echo "Failed drill inputs/container $RUN and owned data volume $DATA retained; evidence $EVIDENCE" >&2
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
docker volume create --label "omega.acceptance.run=$RUN" "$DATA" >/dev/null
MOUNTS=(--mount "type=volume,src=$DATA,dst=/var/lib/docker" --mount "type=bind,src=$ARCHIVE,dst=/candidate.tar,readonly" --mount "type=bind,src=$EVIDENCE/operator,dst=/operator,readonly")
if [ -n "$OLD_ARCHIVE" ]; then
  OLD_ARCHIVE=$(cd "$(dirname "$OLD_ARCHIVE")" && pwd -P)/$(basename "$OLD_ARCHIVE")
  MOUNTS+=(--mount "type=bind,src=$OLD_ARCHIVE,dst=/old.tar,readonly")
fi
docker run -d --pull never --platform linux/amd64 --name "$RUN" --label "omega.acceptance.run=$RUN" --privileged --network none -e DOCKER_TLS_CERTDIR= "${MOUNTS[@]}" "$HARNESS" --tls=false >/dev/null
for attempt in $(seq 1 60); do
  if bounded 3 docker exec "$RUN" docker info >/dev/null 2>&1; then break; fi
  [ "$attempt" -lt 60 ] || fail 'isolated daemon startup timed out'
  sleep 1
done
{
  uname -sm; docker version; docker image inspect --platform linux/amd64 --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$HARNESS"
  docker exec "$RUN" apk info -v
  echo 'Linux amd64 emulation on macOS is not native Linux amd64 acceptance.'
} > "$EVIDENCE/platform.txt"
docker exec "$RUN" bash /operator/target.sh "$ARCHIVE_SHA" "$VERSION" "$MANIFEST_SHA" "$OLD_SHA" "$OLD_VERSION" "$OLD_MANIFEST" > "$EVIDENCE/drill.log" 2>&1 & CHILD=$!
result=0; wait "$CHILD" || result=$?; CHILD=''
[ "$result" = 0 ] || exit "$result"
echo "Offline drill passed; evidence: $EVIDENCE. Native acceptance remains separate."
