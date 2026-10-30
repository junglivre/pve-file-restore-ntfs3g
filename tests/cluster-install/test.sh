#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
LOG="$TMP/log"
mkdir -p "$BIN" "$LOG"
export TEST_LOG="$LOG"
export PATH="$BIN:$PATH"

cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
cat > "$BIN/pvesh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"type":"node","online":1,"name":"pve-a"}]'
EOF
cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$TEST_LOG/ssh"
printf '\n' >> "$TEST_LOG/ssh"
case "$*" in
  *'mktemp -d'*) printf '/tmp/pve-file-restore-test\n' ;;
  *'dpkg-query'*) printf '4.2.8-1+ntfs3g3|1.0.0+ntfs3g4|ATIVO\n' ;;
  *'bash -s'* ) cat > "$TEST_LOG/remote-script" ;;
esac
EOF
cat > "$BIN/scp" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$TEST_LOG/scp"
printf '\n' >> "$TEST_LOG/scp"
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=${!#}
base=$(basename "$out")
component=$(basename "$(dirname "$out")")
case "$component" in
  file-restore) deb='proxmox-backup-file-restore_4.2.8-1+ntfs3g3_amd64.deb' ;;
  restore-image) deb='proxmox-backup-restore-image_1.0.0+ntfs3g4_amd64.deb' ;;
  meta) deb='pve-file-restore-ntfs3g_2.1.1_all.deb' ;;
  *) exit 2 ;;
esac
if [ "$base" = SHA256SUMS ]; then
  printf '%s  %s\n' "$(printf '%s\n' "$deb" | sha256sum | cut -d' ' -f1)" "$deb" > "$out"
else
  printf '%s\n' "$base" > "$out"
fi
EOF
chmod +x "$BIN"/*

cat > "$TMP/releases.json" <<'EOF'
[
  {"tag_name":"file-restore/4.2.8-1+ntfs3g3","prerelease":false,"assets":[{"name":"proxmox-backup-file-restore_4.2.8-1+ntfs3g3_amd64.deb","browser_download_url":"https://example.invalid/fr"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/frsum"}]},
  {"tag_name":"restore-image/1.0.0+ntfs3g4","prerelease":false,"assets":[{"name":"proxmox-backup-restore-image_1.0.0+ntfs3g4_amd64.deb","browser_download_url":"https://example.invalid/ri"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/risum"}]},
  {"tag_name":"meta/2.1.1","prerelease":false,"assets":[{"name":"pve-file-restore-ntfs3g_2.1.1_all.deb","browser_download_url":"https://example.invalid/meta"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/metasum"}]}
]
EOF
export PVE_FILE_RESTORE_RELEASES_URL="file://$TMP/releases.json"

# Online download verifies each release's isolated SHA256SUMS. --dry-run must
# not create a remote directory, connect through SSH, or copy anything.
"$ROOT/scripts/cluster-install.sh" --dry-run > "$TMP/dry-run.out"
[ ! -e "$LOG/ssh" ] && [ ! -e "$LOG/scp" ]
grep -qF 'copy verified packages' "$TMP/dry-run.out"

# --check remains read-only and keeps the dpkg-query format literal for the
# remote shell; the mock returns a populated status row.
"$ROOT/scripts/cluster-install.sh" --check > "$TMP/check.out"
grep -qF '4.2.8-1+ntfs3g3' "$TMP/check.out"
grep -qF "\${Version}" "$LOG/ssh"

# Offline input requires one release directory and an individual SHA file per
# component. It reaches the remote install path only after verification.
FROM="$TMP/from"
for component in file-restore restore-image meta; do
  mkdir -p "$FROM/$component"
  case "$component" in
    file-restore) deb='proxmox-backup-file-restore_4.2.8-1+ntfs3g3_amd64.deb' ;;
    restore-image) deb='proxmox-backup-restore-image_1.0.0+ntfs3g4_amd64.deb' ;;
    meta) deb='pve-file-restore-ntfs3g_2.1.1_all.deb' ;;
  esac
  printf '%s\n' "$deb" > "$FROM/$component/$deb"
  (cd "$FROM/$component" && sha256sum "$deb" > SHA256SUMS)
done
"$ROOT/scripts/cluster-install.sh" --from-dir "$FROM" --hold > "$TMP/install.out"
grep -qF 'apt_flags+=(' "$LOG/remote-script"
grep -qF 'allow-change-held-packages' "$LOG/remote-script"
grep -qF 'pve-file-restore-ntfs3g-check' "$LOG/remote-script"
[ -s "$LOG/scp" ]

# A component whose listed hash does not match is rejected before SSH.
printf '%064d  proxmox-backup-file-restore_4.2.8-1+ntfs3g3_amd64.deb\n' 0 > "$FROM/file-restore/SHA256SUMS"
if "$ROOT/scripts/cluster-install.sh" --from-dir "$FROM" > "$TMP/bad.out" 2>&1; then
  echo 'checksum mismatch unexpectedly installed' >&2
  exit 1
fi
grep -q 'FAILED' "$TMP/bad.out"
