#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <package.deb>" >&2; exit 2; }
deb=$1
[ -f "$deb" ] || { echo "package not found: $deb" >&2; exit 1; }

package=$(dpkg-deb -f "$deb" Package)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$deb" "$tmp"
# Non-native packages ship changelog.Debian.gz; native ones (the restore
# image) ship changelog.gz.
changelog="$tmp/usr/share/doc/$package/changelog.Debian.gz"
[ -f "$changelog" ] || changelog="$tmp/usr/share/doc/$package/changelog.gz"
[ -f "$changelog" ] || { echo "missing compressed changelog in $deb" >&2; exit 1; }
# Decompress fully before grep -q: GitHub runners start steps with SIGPIPE
# ignored, so a gzip cut off by an early grep exit fails with "Broken pipe".
gzip -dc "$changelog" > "$tmp/changelog"
grep -qF 'Rebuild with the pve-file-restore-ntfs3g patch set.' "$tmp/changelog"
echo "changelog check passed: $deb"
