#!/usr/bin/env bash
# Probe only real input-selection behavior; no database or credentials are created.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/omega input policy.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/source"
git -C "$ROOT" archive HEAD | tar -xpf - -C "$WORK/source"
check() {
  local expected=$1 path=$2 message=$3 code=0
  mkdir -p "$path"
  "$WORK/source/scripts/dev.sh" status --input "$path" > "$WORK/stdout" 2> "$WORK/stderr" || code=$?
  [ "$code" -eq "$expected" ] || { cat "$WORK/stderr" >&2; echo "input policy: expected $expected got $code" >&2; exit 1; }
  grep -q "$message" "$WORK/stderr"
  [ ! -e "$path/instance.env" ] && [ ! -e "$path/secrets" ] && [ ! -e "$path/.lock" ]
  printf 'PASS input=%s exit=%s diagnostic=%s\n' "$path" "$code" "$message"
}
check 3 "$WORK/source/unmanaged inputs" 'inputs inside the source tree must be under .omega'
check 2 "$WORK/source/.omega/spaced inputs" 'missing instance.env'
check 2 "$WORK/external inputs" 'missing instance.env'
echo 'Allowed paths passed location policy and reached the expected absent-identity check; this probe does not claim an additional full startup.'
