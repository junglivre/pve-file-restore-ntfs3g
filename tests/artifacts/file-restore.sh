#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=./tests/artifacts/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ "$#" -eq 1 ] || { echo "usage: $0 <file-restore.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

version=$(dpkg-deb -f "$deb" Version)
deb_relation_has "$deb" Provides "proxmox-backup-file-restore-ntfs3g (= $version)"
deb_relation_has "$deb" Provides 'pve-file-restore-ntfs3g-daemon (= 2)'
grep -qF 'Maintainer: junglivre <junglivre@users.noreply.github.com>' < <(dpkg-deb -I "$deb")

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
