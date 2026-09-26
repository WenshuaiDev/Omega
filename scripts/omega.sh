#!/usr/bin/env bash
# Same-source application CLI in the selected, already prepared dev instance.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$ROOT/scripts/dev.sh" omega "$@"
