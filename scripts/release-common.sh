#!/usr/bin/env bash
# Shared release primitives. Manifest data is never evaluated as shell.
set -Eeuo pipefail
umask 077
fail() { echo "omega release: $*" >&2; exit 2; }
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}';
  else fail 'sha256sum or shasum is required'; fi
}
prerequisites() {
  local utility
  for utility in docker bash tar awk find sort curl; do command -v "$utility" >/dev/null || fail "missing prerequisite: $utility"; done
  docker info >/dev/null 2>&1 || fail 'Docker daemon unavailable'
  docker compose version >/dev/null || fail 'Docker Compose plugin required'
  docker version --format '{{.Client.APIVersion}} {{.Server.APIVersion}}' | awk '{split($1,c,"."); split($2,s,"."); exit !(c[1]>=1 && c[2]>=49 && s[1]>=1 && s[2]>=49)}' || fail 'Docker client/server API1.49+ required for platform-specific identity verification'
}
verify_manifest() {
  local root=$1 expected=$2 kind a b c d e extra seen=' ' file_count=0 image_count=0
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail 'explicit trusted manifest SHA256 required'
  [ "$(sha256 "$root/manifest.tsv")" = "$expected" ] || fail 'manifest differs from trusted SHA256'
  RELEASE_VERSION=''; RELEASE_COMMIT=''; TOOLS_IMAGE=''
  IMAGE_ROLES=(); IMAGE_REFS=(); IMAGE_IDS=()
  while IFS=$'\t' read -r kind a b c d e extra; do
    case "$kind" in
      format) [ "$a" = omega-release-v1 ] && [ -z "$b" ] || fail 'invalid manifest format' ;;
      release)
        [ -z "$RELEASE_VERSION" ] && [[ "$a" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] && [[ "$b" =~ ^[a-f0-9]{40}$ ]] && [ "$c" = linux/amd64 ] && [ -z "$d" ] || fail 'invalid release metadata'
        RELEASE_VERSION=$a; RELEASE_COMMIT=$b ;;
      compatibility) [ "$a" = config-v1 ] && [[ "$b" =~ ^[0-9]+$ ]] && [[ "$c" =~ ^[0-9]+$ ]] && [ -z "$d" ] || fail 'invalid compatibility declaration' ;;
      image)
        case "$a" in api|web|console|edge|tools|db) ;; *) fail 'invalid image role' ;; esac
        case "$seen" in *" $a "*) fail 'duplicate image role' ;; esac
        seen="$seen$a "
        [[ "$b" =~ ^omega-release/[a-z]+:[a-zA-Z0-9._-]+$ ]] && [[ "$c" =~ ^sha256:[a-f0-9]{64}$ ]] && [ "$d" = linux/amd64 ] && [ -z "$e" ] || fail 'invalid image identity'
        IMAGE_ROLES+=("$a"); IMAGE_REFS+=("$b"); IMAGE_IDS+=("$c"); image_count=$((image_count + 1))
        [ "$a" != tools ] || TOOLS_IMAGE=$c ;;
      file)
        [[ "$a" =~ ^[a-f0-9]{64}$ ]] && [[ "$b" =~ ^[a-zA-Z0-9_./-]+$ ]] && [ -z "$c" ] || fail 'invalid file record'
        case "$b" in /*|*..*|manifest.tsv) fail 'unsafe manifest path' ;; esac
        [ -f "$root/$b" ] && [ ! -L "$root/$b" ] && [ "$(sha256 "$root/$b")" = "$a" ] || fail "file integrity failed: $b"
        file_count=$((file_count + 1)) ;;
      *) fail 'unknown manifest record' ;;
    esac
  done < "$root/manifest.tsv"
  [ "$image_count" = 6 ] && [ "$file_count" -gt 5 ] && [ -n "$RELEASE_VERSION" ] || fail 'incomplete manifest'
  [ -z "$(find "$root" -type l -print -quit)" ] || fail 'release symlinks are forbidden'
  [ "$(find "$root" -type f | wc -l | tr -d ' ')" = "$((file_count + 1))" ] || fail 'unlisted release files'
}
verify_images() {
  local i actual
  for i in "${!IMAGE_ROLES[@]}"; do
    actual=$(docker image inspect --platform linux/amd64 --format '{{.Id}} {{.Os}}/{{.Architecture}}' "${IMAGE_REFS[$i]}" 2>/dev/null) || fail "missing local image: ${IMAGE_ROLES[$i]}; import verified archive first (no pull attempted)"
    [ "$actual" = "${IMAGE_IDS[$i]} linux/amd64" ] || fail "image content/platform mismatch: ${IMAGE_ROLES[$i]}"
  done
}
