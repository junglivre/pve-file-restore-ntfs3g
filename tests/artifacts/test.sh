#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/tests/artifacts/check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ARTIFACTS="$TMP/artifacts"
mkdir -p "$ARTIFACTS"

# shellcheck source=./tests/artifacts/lib.sh
source "$ROOT/tests/artifacts/lib.sh"

make_relation_deb() {
    local name=$1 provides=$2 depends=$3 build="$TMP/$1-build"
    mkdir -p "$build/DEBIAN"
    printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: test <test@example.invalid>\nProvides: %s\nDepends: %s\nDescription: relation test\n relation test\n' \
        "$name" "$provides" "$depends" > "$build/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$build" "$TMP/$name.deb" >/dev/null
}

make_relation_deb relation-single \
    'relation-provide (= 1), relation-provide-extra (= 1)' \
    'relation-dependency (>= 1), relation-dependency-extra (>= 1)'
make_relation_deb relation-multi \
    $'relation-provide-multi (= 1),\n relation-provide-multi-extra (= 1)' \
    $'relation-dependency-multi (>= 1),\n relation-dependency-multi-extra (>= 1)'

deb_relation_has "$TMP/relation-single.deb" Provides 'relation-provide (= 1)'
deb_relation_has "$TMP/relation-single.deb" Depends 'relation-dependency (>= 1)'
deb_relation_has "$TMP/relation-multi.deb" Provides 'relation-provide-multi-extra (= 1)'
deb_relation_has "$TMP/relation-multi.deb" Depends 'relation-dependency-multi-extra (>= 1)'
for relation in \
    "$TMP/relation-single.deb|Provides|relation-provide (= 2)" \
    "$TMP/relation-single.deb|Depends|relation-dependency (>= 2)" \
    "$TMP/relation-multi.deb|Provides|relation-provide-multi-extra (= 2)" \
    "$TMP/relation-multi.deb|Depends|relation-dependency-multi-extra (>= 2)"; do
    deb=${relation%%|*}
    remainder=${relation#*|}
    field=${remainder%%|*}
    expected=${remainder#*|}
    if deb_relation_has "$deb" "$field" "$expected"; then
        echo "unexpected relation match: $field $expected" >&2
        exit 1
    fi
done

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
