#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <meta.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

control=$(dpkg-deb -I "$deb")
grep -qF 'Depends: proxmox-backup-file-restore-ntfs3g' <<<"$control"
grep -qF 'proxmox-backup-restore-image-ntfs3g' <<<"$control"
echo "meta artifact checks passed: $deb"
