#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=./tests/artifacts/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ "$#" -eq 1 ] || { echo "usage: $0 <meta.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

deb_relation_has "$deb" Depends 'initramfs-tools-core'
deb_relation_has "$deb" Depends 'pve-file-restore-ntfs3g-daemon (>= 2)'
deb_relation_has "$deb" Depends 'pve-file-restore-ntfs3g-image (>= 3)'
echo "meta artifact checks passed: $deb"
