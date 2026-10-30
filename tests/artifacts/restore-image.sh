#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <restore-image.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

control=$(dpkg-deb -I "$deb")
grep -qF 'Provides: proxmox-backup-restore-image-ntfs3g' <<<"$control"
grep -qF 'Maintainer: pve-file-restore-ntfs3g' <<<"$control"

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
