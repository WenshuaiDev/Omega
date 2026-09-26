#!/usr/bin/env bash
# Isolated PostgreSQL + real executable tests. No host Go installation required.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
name="omega-api-test-$(date +%s)-$$"
cleanup() {
  docker rm -f "$name-go" "$name-db" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
docker network create "$name" >/dev/null
docker run -d --name "$name-db" --network "$name" --network-alias db \
  --tmpfs /var/lib/postgresql/data -e POSTGRES_DB=omega -e POSTGRES_PASSWORD=admin-secret \
  postgres:17.10-alpine >/dev/null
ready=0
for ((i=0;i<60;i++)); do
  if docker exec "$name-db" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || { echo 'test PostgreSQL failed to become ready' >&2; exit 5; }
docker run --rm --name "$name-go" --network "$name" \
  --mount "type=bind,src=$root,dst=/workspace,readonly" -w /workspace \
  -e GOFLAGS=-mod=readonly -e GOTOOLCHAIN=local \
  -e 'OMEGA_TEST_ADMIN_DSN=postgres://postgres:admin-secret@db:5432/omega?sslmode=disable' \
  golang:1.27.1-bookworm go test -count=1 -v ./services/api/...
