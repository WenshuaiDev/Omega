#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/release-common.sh"
[ "$#" = 2 ] || fail 'usage: build-release.sh VERSION NEW_OUTPUT_DIRECTORY'
VERSION=$1; OUTPUT=$2
[[ "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] && [ "$VERSION" != latest ] || fail 'explicit immutable release version required'
prerequisites
[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail 'release build requires a clean committed checkout'
[ ! -e "$OUTPUT" ] || fail 'output exists; builds never overwrite releases'
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
for role in api web console edge tools db; do
  if docker image inspect "omega-release/$role:$VERSION" >/dev/null 2>&1; then fail "release version already has local image $role; choose a new version (never rebuild an accepted version)"; fi
done
mkdir -p "$OUTPUT/materials/scripts" "$OUTPUT/materials/infra/db" "$OUTPUT/templates" "$OUTPUT/evidence"
OUTPUT=$(cd "$OUTPUT" && pwd -P)
case "$OUTPUT" in "$ROOT"/*) fail 'release output must be outside build context' ;; esac
for role in api web console edge tools; do
  case "$role" in
    api) file=services/api/Dockerfile; args=(--target production) ;;
    web|console) file=apps/Dockerfile; args=(--target production --build-arg "APP=$role") ;;
    *) file="infra/$role/Dockerfile"; args=() ;;
  esac
  docker build --platform linux/amd64 -f "$ROOT/$file" "${args[@]}" --build-arg "VERSION=$VERSION" --build-arg "COMMIT=$COMMIT" -t "omega-release/$role:$VERSION" "$ROOT"
done
docker pull --platform linux/amd64 postgres:17.10-alpine
docker tag postgres:17.10-alpine "omega-release/db:$VERSION"
IMAGES=()
for role in api web console edge tools db; do IMAGES+=("omega-release/$role:$VERSION"); done
docker image save --platform linux/amd64 --output "$OUTPUT/images.tar" "${IMAGES[@]}"
cp "$ROOT"/compose{,.release,.test,.prod}.yaml "$OUTPUT/materials/"
cp "$ROOT/scripts/"{release,release-common,import-release}.sh "$OUTPUT/materials/scripts/"
cp "$ROOT/infra/db/10-omega.sh" "$OUTPUT/materials/infra/db/"
cp "$ROOT/config/templates/"* "$OUTPUT/templates/"
cp "$ROOT/docs/implementation/release.md" "$OUTPUT/OPERATIONS.md"
docker run --rm --pull never --platform linux/amd64 --network none --entrypoint omega "omega-release/api:$VERSION" --json version > "$OUTPUT/evidence/api-version.json"
docker run --rm --pull never --platform linux/amd64 --network none --mount "type=bind,src=$OUTPUT,dst=/release" "omega-release/tools:$VERSION" python /tools/release.py build-evidence /release "$VERSION" "$COMMIT"
{
  printf 'format\tomega-release-v1\nrelease\t%s\t%s\tlinux/amd64\n' "$VERSION" "$COMMIT"
  docker run --rm --pull never --platform linux/amd64 --network none --mount "type=bind,src=$OUTPUT,dst=/release,readonly" "omega-release/tools:$VERSION" python /tools/release.py compatibility /release
  for role in api web console edge tools db; do
    ref="omega-release/$role:$VERSION"
    printf 'image\t%s\t%s\t%s\t%s\n' "$role" "$ref" "$(docker image inspect --format '{{.Id}}' "$ref")" "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref")"
  done
} > "$OUTPUT/manifest.tsv"
while IFS= read -r file; do
  relative=${file#"$OUTPUT/"}
  [ "$relative" = manifest.tsv ] || printf 'file\t%s\t%s\n' "$(sha256 "$file")" "$relative" >> "$OUTPUT/manifest.tsv"
done < <(find "$OUTPUT" -type f | LC_ALL=C sort)
verify_manifest "$OUTPUT" "$(sha256 "$OUTPUT/manifest.tsv")"
verify_images
tar -cf "$OUTPUT.tar" -C "$OUTPUT" .
printf 'Release: %s\nCommit: %s\nArchive: %s.tar\nTrusted archive SHA256: %s\nTrusted manifest SHA256: %s\n' "$VERSION" "$COMMIT" "$OUTPUT" "$(sha256 "$OUTPUT.tar")" "$(sha256 "$OUTPUT/manifest.tsv")"
