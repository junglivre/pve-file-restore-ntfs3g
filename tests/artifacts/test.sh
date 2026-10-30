#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/tests/artifacts/check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ARTIFACTS="$TMP/artifacts"
mkdir -p "$ARTIFACTS"

for component in file-restore restore-image dedup-plugin meta; do
    case $component in
        file-restore) package='proxmox-backup-file-restore_fake.deb' ;;
        restore-image) package='proxmox-backup-restore-image_fake.deb' ;;
        dedup-plugin) package='ntfs-3g-plugin-dedup_fake.deb' ;;
        meta) package='pve-file-restore-ntfs3g_fake.deb' ;;
    esac
    directory="$ARTIFACTS/$component"
    mkdir -p "$directory"
    printf 'not a real Debian package\n' > "$directory/$package"
    (cd "$directory" && sha256sum -- "$package" > SHA256SUMS)
done

"$SCRIPT" "$ARTIFACTS" > "$TMP/checksums.out"
if "$SCRIPT" "$ARTIFACTS" file-restore > "$TMP/selected.out" 2>&1; then
    echo 'selected component unexpectedly passed content checks' >&2
    exit 1
fi

printf 'artifact selection tests passed\n'
