#!/usr/bin/env bash
# This bootstrap must itself come from the trusted operator distribution.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/release-common.sh"
[ "$#" = 3 ] || fail 'usage: import-release.sh ARCHIVE TRUSTED_ARCHIVE_SHA256 NEW_DESTINATION'
ARCHIVE=$1; EXPECTED=$2; DEST=$3
prerequisites
[[ "$EXPECTED" =~ ^[a-f0-9]{64}$ ]] && [ "$(sha256 "$ARCHIVE")" = "$EXPECTED" ] || fail 'archive differs from independently trusted SHA256; nothing imported'
[ ! -e "$DEST" ] || fail 'destination already exists; select a new immutable release directory'
# Authenticated archives still reject absolute/traversal/links/special entries.
tar -tf "$ARCHIVE" | awk '/^\// || /(^|\/)\.\.($|\/)/ {exit 1}' || fail 'unsafe archive path'
tar -tvf "$ARCHIVE" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' || fail 'archive must contain only regular files and directories'
mkdir -p "$DEST"
tar -xf "$ARCHIVE" -C "$DEST"
MANIFEST_SHA=$(sha256 "$DEST/manifest.tsv")
verify_manifest "$DEST" "$MANIFEST_SHA"
docker load --input "$DEST/images.tar"
verify_images
printf 'Imported verified release %s\nManifest SHA256: %s\nArchive SHA256: %s\n' "$RELEASE_VERSION" "$MANIFEST_SHA" "$EXPECTED"
