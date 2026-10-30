#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <package.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

package=$(dpkg-deb -f "$deb" Package)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$deb" "$tmp"
changelog="$tmp/usr/share/doc/$package/changelog.Debian.gz"
[ -f "$changelog" ] || { echo "missing compressed changelog in $deb" >&2; exit 1; }
zgrep -qF 'Rebuild with the pve-file-restore-ntfs3g patch set.' "$changelog"
echo "changelog check passed: $deb"
