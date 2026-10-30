#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <file-restore.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

control=$(dpkg-deb -I "$deb")
grep -qF 'Provides: proxmox-backup-file-restore-ntfs3g' <<<"$control"
grep -qF 'Maintainer: pve-file-restore-ntfs3g' <<<"$control"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$deb" "$tmp"
daemon="$tmp/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon"
[ -r "$daemon" ] || { echo "missing restore daemon in $deb" >&2; exit 1; }
daemon_strings=$(strings "$daemon")
grep -qF 'try FUSE mount using ntfs-3g' <<<"$daemon_strings"
grep -qF 'remounting with ntfs-3g' <<<"$daemon_strings"
"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/changelog.sh" "$deb"
echo "file-restore artifact checks passed: $deb"
