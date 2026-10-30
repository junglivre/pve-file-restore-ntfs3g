#!/usr/bin/env bash
# Prove that restore-image embeds exactly the packaged dedup plugin bytes.
set -Eeuo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <restore-image.deb> <dedup-plugin.deb>" >&2; exit 2; }
restore_image=$1
plugin_deb=$2
[ -f "$restore_image" ] || { echo "package not found: $restore_image" >&2; exit 1; }
[ -f "$plugin_deb" ] || { echo "package not found: $plugin_deb" >&2; exit 1; }

plugin_path=usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dpkg-deb -x "$plugin_deb" "$tmp/plugin"
plugin_so="$tmp/plugin/$plugin_path"
[ -f "$plugin_so" ] || { echo "plugin package lacks $plugin_path" >&2; exit 1; }

dpkg-deb -x "$restore_image" "$tmp/image"
initramfs="$tmp/image/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
[ -f "$initramfs" ] || { echo "restore image lacks initramfs.img" >&2; exit 1; }

count=$(lsinitramfs "$initramfs" | awk -v path="$plugin_path" '$0 == path { count++ } END { print count + 0 }')
[ "$count" -eq 1 ] || { echo "expected exactly one $plugin_path in initramfs, got $count" >&2; exit 1; }
unmkinitramfs "$initramfs" "$tmp/initramfs"
mapfile -t embedded < <(find "$tmp/initramfs" -type f -path "*/$plugin_path" -print)
[ "${#embedded[@]}" -eq 1 ] || {
    echo "expected exactly one extracted $plugin_path, got ${#embedded[@]}" >&2
    exit 1
}

packaged_hash=$(sha256sum "$plugin_so" | awk '{print $1}')
embedded_hash=$(sha256sum "${embedded[0]}" | awk '{print $1}')
[ "$packaged_hash" = "$embedded_hash" ] || {
    echo "embedded plugin hash differs from package" >&2
    echo "package:   $packaged_hash" >&2
    echo "initramfs: $embedded_hash" >&2
    exit 1
}
echo "plugin match passed: $embedded_hash"
