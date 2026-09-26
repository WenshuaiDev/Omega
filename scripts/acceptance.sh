#!/usr/bin/env bash
# Fixed suite dispatcher, not an acceptance-result generator or deployment engine.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
SUITE=${1:-help}; [ "$#" = 0 ] || shift
OUTPUT="$ROOT/artifacts/acceptance-$(date +%s)-$$"
ARCHIVE=''; ARCHIVE_SHA=''; VERSION=''; MANIFEST_SHA=''; HARNESS=''
OLD_ARCHIVE=''; OLD_SHA=''; OLD_VERSION=''; OLD_MANIFEST=''
usage() {
  echo 'Usage: scripts/acceptance.sh quality|dev|browser|release|all [--output NEW_DIRECTORY]'
  echo 'release/all require --archive FILE --archive-sha256 HASH --version VERSION --manifest-sha256 HASH --harness-image IMAGE'
  echo 'Optional rollback candidate: --old-archive FILE --old-archive-sha256 HASH --old-version VERSION --old-manifest-sha256 HASH'
  echo 'quality delegates check.sh; dev delegates acceptance-dev.sh; browser owns a disposable dev stack; release delegates accept-release.sh.'
  echo 'All suites require committed clean source. Build the release candidate and offline harness separately before release/all.'
  echo 'Missing/unrun suites never pass. Complete OMEGA evidence and native platform acceptance are separate records.'
}
case "$SUITE" in quality|dev|browser|release) SUITES=("$SUITE");; all) SUITES=(quality dev browser release);; help|--help|-h) usage; exit 0;; *) usage >&2; exit 2;; esac
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  case "$1" in
    --output) OUTPUT=$2;; --archive) ARCHIVE=$2;; --archive-sha256) ARCHIVE_SHA=$2;; --version) VERSION=$2;; --manifest-sha256) MANIFEST_SHA=$2;; --harness-image) HARNESS=$2;;
    --old-archive) OLD_ARCHIVE=$2;; --old-archive-sha256) OLD_SHA=$2;; --old-version) OLD_VERSION=$2;; --old-manifest-sha256) OLD_MANIFEST=$2;;
    *) usage >&2; exit 2;;
  esac
  shift 2
done
if [ "$SUITE" = release ] || [ "$SUITE" = all ]; then
  [ -f "$ARCHIVE" ] && [ -n "$ARCHIVE_SHA" ] && [ -n "$VERSION" ] && [ -n "$MANIFEST_SHA" ] && [ -n "$HARNESS" ] || { echo 'release suite requires explicit candidate/harness inputs' >&2; exit 2; }
  if [ -n "$OLD_ARCHIVE$OLD_SHA$OLD_VERSION$OLD_MANIFEST" ]; then
    [ -f "$OLD_ARCHIVE" ] && [ -n "$OLD_SHA" ] && [ -n "$OLD_VERSION" ] && [ -n "$OLD_MANIFEST" ] || { echo 'all four old-candidate arguments are required together' >&2; exit 2; }
  fi
fi
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo 'acceptance requires committed clean source' >&2; exit 2; }
[ ! -e "$OUTPUT" ] || { echo 'use a new evidence directory' >&2; exit 2; }
mkdir -p "$OUTPUT/state"; OUTPUT=$(cd "$OUTPUT" && pwd -P)
ACTIVE=''; CHILD=''
cleanup() {
  code=$?; trap - EXIT INT TERM
  [ -z "$CHILD" ] || { kill -TERM "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; }
  if [ -n "$ACTIVE" ]; then printf '%s\tFAIL\t%s\t%s/\n' "$ACTIVE" "$code" "$ACTIVE" > "$OUTPUT/state/$ACTIVE.tsv"; fi
  printf 'suite\tstatus\texit\tevidence\n' > "$OUTPUT/results.tsv"
  for item in "${SUITES[@]}"; do cat "$OUTPUT/state/$item.tsv" >> "$OUTPUT/results.tsv"; done
  printf 'local_run_exit=%s\nspec_complete=false\nnative_platform=separate-pending-20\n' "$code" > "$OUTPUT/result.txt"
  echo "Acceptance execution report: $OUTPUT; full specification/native completion is not implied."
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
{
  printf 'source_commit=%s\nrequested_suite=%s\nstarted_at=%s\n' "$(git -C "$ROOT" rev-parse HEAD)" "$SUITE" "$(date -u +%FT%TZ)"
  uname -sm
  docker version --format 'server={{.Server.Version}}/{{.Server.Os}}/{{.Server.Arch}}'
  printf 'archive_sha256=%s\nmanifest_sha256=%s\n' "$ARCHIVE_SHA" "$MANIFEST_SHA"
} > "$OUTPUT/platform.txt"
for item in "${SUITES[@]}"; do
  printf '%s\tNOT_EXECUTED\t-\t%s/\n' "$item" "$item" > "$OUTPUT/state/$item.tsv"
done
for item in "${SUITES[@]}"; do
  case "$item" in quality) entry=scripts/check.sh;; dev) entry=scripts/acceptance-dev.sh;; browser) entry=scripts/acceptance/browser.sh;; release) entry=scripts/accept-release.sh;; esac
  [ -x "$ROOT/$entry" ] || { echo "requested suite is unavailable: $entry" >&2; exit 2; }
done
for item in "${SUITES[@]}"; do
  ACTIVE=$item
  case "$item" in
    quality) COMMAND=("$ROOT/scripts/check.sh" --output "$OUTPUT/quality");;
    dev) COMMAND=("$ROOT/scripts/acceptance-dev.sh" --output "$OUTPUT/dev");;
    browser) COMMAND=("$ROOT/scripts/acceptance/browser.sh" --output "$OUTPUT/browser");;
    release)
      COMMAND=("$ROOT/scripts/accept-release.sh" "$ARCHIVE" "$ARCHIVE_SHA" "$VERSION" "$MANIFEST_SHA" "$HARNESS" "$OUTPUT/release")
      [ -z "$OLD_ARCHIVE" ] || COMMAND+=("$OLD_ARCHIVE" "$OLD_SHA" "$OLD_VERSION" "$OLD_MANIFEST");;
  esac
  printf '%q ' "${COMMAND[@]}" > "$OUTPUT/$item.argv"; printf '\n' >> "$OUTPUT/$item.argv"
  echo "Running acceptance suite: $item"
  "${COMMAND[@]}" > "$OUTPUT/$item.log" 2>&1 & CHILD=$!
  result=0; wait "$CHILD" || result=$?; CHILD=''
  printf '%s\t%s\t%s\t%s/\n' "$item" "$([ "$result" = 0 ] && echo PASS || echo FAIL)" "$result" "$item" > "$OUTPUT/state/$item.tsv"
  ACTIVE=''
  [ "$result" = 0 ] || exit "$result"
done
