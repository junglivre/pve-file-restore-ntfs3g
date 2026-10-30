#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=./tests/artifacts/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ "$#" -eq 1 ] || { echo "usage: $0 <restore-image.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

version=$(dpkg-deb -f "$deb" Version)
deb_relation_has "$deb" Provides "proxmox-backup-restore-image-ntfs3g (= $version)"
deb_relation_has "$deb" Provides 'pve-file-restore-ntfs3g-image (= 3)'
grep -qF 'Maintainer: junglivre <junglivre@users.noreply.github.com>' < <(dpkg-deb -I "$deb")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$deb" "$tmp"
initramfs="$tmp/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
[ -r "$initramfs" ] || { echo "missing restore initramfs in $deb" >&2; exit 1; }
listing=$(lsinitramfs "$initramfs")
grep -qx 'usr/bin/ntfs-3g' <<<"$listing"
grep -qx 'usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so' <<<"$listing"
grep -qF 'libfuse3' <<<"$listing"
"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/changelog.sh" "$deb"
echo "restore-image artifact checks passed: $deb"
