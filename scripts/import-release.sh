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
# Check both local filesystems before extraction or Docker writes. If they
# share a filesystem, reserve both working sets there. Remote daemon paths fail
# closed: the operator must run the importer on the actual target host.
parent=$(dirname -- "$DEST")
while [ ! -e "$parent" ]; do parent=$(dirname -- "$parent"); done
docker_root=$(bounded 15 docker info --format '{{.DockerRootDir}}')
archive_kb=$((($(wc -c < "$ARCHIVE") + 1023) / 1024))
read -r dest_device dest_free < <(df -Pk "$parent" | awk 'END {print $1, $4}') || fail 'cannot measure destination filesystem space'
read -r docker_device docker_free < <(df -Pk "$docker_root" | awk 'END {print $1, $4}') || fail 'cannot measure local Docker filesystem space'
[[ "$dest_free" =~ ^[0-9]+$ ]] && [[ "$docker_free" =~ ^[0-9]+$ ]] || fail 'cannot measure destination/Docker filesystem space on this host'
dest_need=$((archive_kb + 524288)); docker_need=$((archive_kb * 2 + 524288))
if [ "$dest_device" = "$docker_device" ]; then dest_need=$((archive_kb * 3 + 524288)); fi
[ "$dest_free" -ge "$dest_need" ] || fail 'insufficient destination disk space before extraction (archive working set plus512MiB reserve)'
[ "$docker_free" -ge "$docker_need" ] || fail 'insufficient Docker disk space before image import (two archive working sets plus512MiB reserve)'
# Only authenticated public materials retain their modes; never restore archive
# owners or privileged mode bits. Ordinary operators must not turn0755 into0700.
tar -tvf "$ARCHIVE" | awk 'substr($0,1,10) ~ /[sStT]/ {exit 1}' || fail 'privileged archive modes are forbidden'
mkdir -p "$DEST"
tar --no-same-owner --same-permissions -xf "$ARCHIVE" -C "$DEST"
MANIFEST_SHA=$(sha256 "$DEST/manifest.tsv")
verify_manifest "$DEST" "$MANIFEST_SHA"
bounded 1800 docker load --input "$DEST/images.tar"
verify_images
printf 'Imported verified release %s\nManifest SHA256: %s\nArchive SHA256: %s\n' "$RELEASE_VERSION" "$MANIFEST_SHA" "$EXPECTED"
