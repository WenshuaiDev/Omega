#!/usr/bin/env bash
# Same-version application CLI using explicit, verified formal release inputs.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$ROOT/scripts/release.sh" omega "$@"
