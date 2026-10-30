#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
TREE="$TMP/root"
mkdir -p "$BIN" \
  "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore" \
  "$TREE/var/cache/proxmox-backup" \
  "$TREE/var/lib/dpkg/info"
export PATH="$BIN:$PATH"
export PVE_FILE_RESTORE_CHECK_ROOT="$TREE"

cat > "$BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  proxmox-backup-file-restore) printf '%s' "${FILE_RESTORE_VERSION:-}" ;;
  proxmox-backup-restore-image) printf '%s' "${RESTORE_IMAGE_VERSION:-}" ;;
esac
EOF
cat > "$BIN/lsinitramfs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'usr/bin/ntfs-3g' 'usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so'
EOF
chmod +x "$BIN"/*
CHECK="$ROOT/packaging/pve-file-restore-ntfs3g/pve-file-restore-ntfs3g-check"

# Missing packages are JSON null, never the string "null".
if "$CHECK" --json > "$TMP/missing.json" 2>/dev/null; then
  echo 'missing packages unexpectedly passed' >&2
  exit 1
fi
grep -qF '"version": null' "$TMP/missing.json"
if grep -qF '"null"' "$TMP/missing.json"; then
  echo 'JSON null was serialized as a string' >&2
  exit 1
fi

export FILE_RESTORE_VERSION='4.2.8-1+ntfs3g2'
export RESTORE_IMAGE_VERSION='1.0.0+ntfs3g3'
printf '%s\0%s\0' 'try FUSE mount using ntfs-3g' 'remounting with ntfs-3g' \
  > "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon"
: > "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
: > "$TREE/var/lib/dpkg/info/proxmox-backup-file-restore.list"
: > "$TREE/var/lib/dpkg/info/proxmox-backup-restore-image.list"
: > "$TREE/var/cache/proxmox-backup/file-restore-initramfs.img"
touch -d '2026-01-01T00:00:00Z' "$TREE/var/lib/dpkg/info/"*.list
touch -d '2026-01-02T00:00:00Z' "$TREE/var/cache/proxmox-backup/file-restore-initramfs.img"
"$CHECK" --json > "$TMP/active.json"
grep -qF '"ok": true' "$TMP/active.json"
grep -qF '"dedup_remount": true' "$TMP/active.json"
grep -qF '"initramfs_cache_fresh": true' "$TMP/active.json"

# A cache older than either installed package is rejected.
touch -d '2026-01-03T00:00:00Z' "$TREE/var/lib/dpkg/info/proxmox-backup-restore-image.list"
if "$CHECK" --json > "$TMP/stale.json" 2>/dev/null; then
  echo 'stale cache unexpectedly passed' >&2
  exit 1
fi
grep -qF '"initramfs_cache_fresh": false' "$TMP/stale.json"

# An official package with no ntfs-3g markers must not be reported as patched.
touch -d '2026-01-01T00:00:00Z' "$TREE/var/lib/dpkg/info/"*.list
export FILE_RESTORE_VERSION='4.2.8-1'
export RESTORE_IMAGE_VERSION='1.0.0'
printf '%s\0' 'official daemon' \
  > "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon"
if "$CHECK" --json > "$TMP/official.json"; then
  echo 'official packages unexpectedly passed' >&2
  exit 1
fi
grep -qF '"patched": false' "$TMP/official.json"
grep -qF '"ok": false' "$TMP/official.json"

echo 'check-command tests passed'
