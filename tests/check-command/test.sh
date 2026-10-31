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
package=${!#}
format=''
for argument in "$@"; do
  case "$argument" in
    '${Status}'|'${Version}'|'${Provides}') format=$argument ;;
  esac
done
case "$package:$format" in
  proxmox-backup-file-restore:'${Status}') printf '%s' "${FILE_RESTORE_STATUS:-}" ;;
  proxmox-backup-file-restore:'${Version}') printf '%s' "${FILE_RESTORE_VERSION:-}" ;;
  proxmox-backup-file-restore:'${Provides}') printf '%s' "${FILE_RESTORE_PROVIDES:-}" ;;
  proxmox-backup-restore-image:'${Status}') printf '%s' "${RESTORE_IMAGE_STATUS:-}" ;;
  proxmox-backup-restore-image:'${Version}') printf '%s' "${RESTORE_IMAGE_VERSION:-}" ;;
  proxmox-backup-restore-image:'${Provides}') printf '%s' "${RESTORE_IMAGE_PROVIDES:-}" ;;
esac
EOF
cat > "$BIN/lsinitramfs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'usr/bin/ntfs-3g' 'usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so'
EOF
chmod +x "$BIN"/*
CHECK="$ROOT/packaging/pve-file-restore-ntfs3g/pve-file-restore-ntfs3g-check"

"$CHECK" --help > "$TMP/help.out"
grep -qF 'usage: pve-file-restore-ntfs3g-check [--json]' "$TMP/help.out"
if "$CHECK" --unknown > "$TMP/unknown.out" 2>&1; then
  echo 'unknown check argument unexpectedly passed' >&2
  exit 1
fi
grep -qF 'unknown option: --unknown' "$TMP/unknown.out"

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

export FILE_RESTORE_VERSION='4.2.8-1+ntfs3g3'
export RESTORE_IMAGE_VERSION='1.0.0+ntfs3g4'
export FILE_RESTORE_STATUS='install ok installed'
export RESTORE_IMAGE_STATUS='install ok installed'
export FILE_RESTORE_PROVIDES='proxmox-backup-file-restore-ntfs3g (= 4.2.8-1+ntfs3g3), pve-file-restore-ntfs3g-daemon (= 2)'
export RESTORE_IMAGE_PROVIDES='proxmox-backup-restore-image-ntfs3g (= 1.0.0+ntfs3g4), pve-file-restore-ntfs3g-image (= 3)'
printf '%s\0%s\0' 'try FUSE mount using ntfs-3g' 'remounting with ntfs-3g' \
  > "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon"
: > "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
: > "$TREE/var/lib/dpkg/info/proxmox-backup-file-restore.list"
: > "$TREE/var/lib/dpkg/info/proxmox-backup-restore-image.list"
# Build the cache the way the upstream file-restore postinst does: copy the
# base initramfs (an uncompressed newc archive) and append the daemon at its
# root with `cpio -o --format=newc -A`.
mkdir -p "$TMP/base/sbin" "$TMP/daemon"
printf 'init' > "$TMP/base/init"
printf 'tool' > "$TMP/base/sbin/tool"
(cd "$TMP/base" && find . -print | cpio --quiet -o --format=newc) \
  > "$TREE/var/cache/proxmox-backup/file-restore-initramfs.img"
printf '%s\0%s\0' 'try FUSE mount using ntfs-3g' 'remounting with ntfs-3g' \
  > "$TMP/daemon/proxmox-restore-daemon"
(cd "$TMP/daemon" && printf './proxmox-restore-daemon' \
  | cpio --quiet -o --format=newc -A -F "$TREE/var/cache/proxmox-backup/file-restore-initramfs.img")
touch -d '2026-01-01T00:00:00Z' "$TREE/var/lib/dpkg/info/"*.list
touch -d '2026-01-02T00:00:00Z' "$TREE/var/cache/proxmox-backup/file-restore-initramfs.img"
"$CHECK" --json > "$TMP/active.json"
grep -qF '"ok": true' "$TMP/active.json"
grep -qF '"dedup_remount": true' "$TMP/active.json"
grep -qF '"initramfs_cache_fresh": true' "$TMP/active.json"

# Packages put on hold (cluster-install --hold) are still installed.
FILE_RESTORE_STATUS='hold ok installed' RESTORE_IMAGE_STATUS='hold ok installed' \
  "$CHECK" --json > "$TMP/held.json"
grep -qF '"ok": true' "$TMP/held.json"

# A cache older than either installed package is rejected.
touch -d '2026-01-03T00:00:00Z' "$TREE/var/lib/dpkg/info/proxmox-backup-restore-image.list"
if "$CHECK" --json > "$TMP/stale.json" 2>/dev/null; then
  echo 'stale cache unexpectedly passed' >&2
  exit 1
fi
grep -qF '"initramfs_cache_fresh": false' "$TMP/stale.json"

# A package in rc state is ignored even if its old files remain on disk.
export FILE_RESTORE_STATUS='deinstall ok config-files'
if "$CHECK" --json > "$TMP/rc.json" 2>/dev/null; then
  echo 'rc package unexpectedly passed' >&2
  exit 1
fi
grep -qF '"version": null' "$TMP/rc.json"

# An official package with similar strings but without the exact Provides is LOST.
export FILE_RESTORE_STATUS='install ok installed'
export FILE_RESTORE_VERSION='4.2.8-1+ntfs3g3'
export RESTORE_IMAGE_VERSION='1.0.0+ntfs3g4'
export FILE_RESTORE_PROVIDES='proxmox-backup-file-restore-ntfs3g (= 4.2.8-1+ntfs3g3), official-feature (= 9)'
export RESTORE_IMAGE_PROVIDES='proxmox-backup-restore-image-ntfs3g (= 1.0.0+ntfs3g4), official-feature (= 9)'
touch -d '2026-01-01T00:00:00Z' "$TREE/var/lib/dpkg/info/"*.list
printf '%s\0' 'official daemon' \
  > "$TREE/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon"
if "$CHECK" --json > "$TMP/official.json"; then
  echo 'official packages unexpectedly passed' >&2
  exit 1
fi
grep -qF '"patched": false' "$TMP/official.json"
grep -qF '"ok": false' "$TMP/official.json"

echo 'check-command tests passed'
