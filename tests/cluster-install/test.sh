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
printf '%s\n' '[{"type":"node","online":1,"name":"pve-a"},{"type":"node","online":1,"name":"pve-b"},{"type":"node","online":1,"name":"pve-c"}]'
EOF
cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$TEST_LOG/ssh"
printf '\n' >> "$TEST_LOG/ssh"
host=''
for argument in "$@"; do
  case "$argument" in root@*) host=${argument#root@} ;; esac
done
case "$*" in
  *'mktemp -d'*) printf '/tmp/pve-file-restore-test-%s\n' "$host" ;;
  *'/usr/sbin/pve-file-restore-ntfs3g-check --json'*)
    if [ "$host" = pve-b ]; then
      printf '{"ok": false}\n'
      exit 1
    fi
    printf '{"ok": true, "file_restore": {}, "restore_image": {}}\n'
    ;;
  *'bash -s'*)
    cat > "$TEST_LOG/remote-script-$host"
    if [ "$host" = pve-b ]; then
      printf '{"ok": false}\n'
      exit 1
    fi
    printf '{"ok": true, "file_restore": {}, "restore_image": {}}\n'
    ;;
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
  file-restore) deb='proxmox-backup-file-restore_4.2.8-2+ntfs3g1_amd64.deb' ;;
  restore-image) deb='proxmox-backup-restore-image_1.1.0+ntfs3g1_amd64.deb' ;;
  meta) deb='pve-file-restore-ntfs3g_2.2.0_all.deb' ;;
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
  {"tag_name":"file-restore/4.2.8-1+ntfs3g3","prerelease":false,"assets":[{"name":"proxmox-backup-file-restore_4.2.8-1+ntfs3g3_amd64.deb","browser_download_url":"https://example.invalid/fr-old"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/fr-old-sum"}]},
  {"tag_name":"file-restore/4.2.8-2+ntfs3g1","prerelease":false,"assets":[{"name":"proxmox-backup-file-restore_4.2.8-2+ntfs3g1_amd64.deb","browser_download_url":"https://example.invalid/fr"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/frsum"}]},
  {"tag_name":"restore-image/1.0.0+ntfs3g4","prerelease":false,"assets":[{"name":"proxmox-backup-restore-image_1.0.0+ntfs3g4_amd64.deb","browser_download_url":"https://example.invalid/ri-old"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/ri-old-sum"}]},
  {"tag_name":"restore-image/1.1.0+ntfs3g1","prerelease":false,"assets":[{"name":"proxmox-backup-restore-image_1.1.0+ntfs3g1_amd64.deb","browser_download_url":"https://example.invalid/ri"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/risum"}]},
  {"tag_name":"meta/2.1.1","prerelease":false,"assets":[{"name":"pve-file-restore-ntfs3g_2.1.1_all.deb","browser_download_url":"https://example.invalid/meta-old"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/meta-old-sum"}]},
  {"tag_name":"meta/2.2.0","prerelease":false,"assets":[{"name":"pve-file-restore-ntfs3g_2.2.0_all.deb","browser_download_url":"https://example.invalid/meta"},{"name":"SHA256SUMS","browser_download_url":"https://example.invalid/metasum"}]}
]
EOF
export PVE_FILE_RESTORE_RELEASES_URL="file://$TMP/releases.json"

# Online download verifies each release's isolated SHA256SUMS. --dry-run must
# not create a remote directory, connect through SSH, or copy anything.
"$ROOT/scripts/cluster-install.sh" --dry-run > "$TMP/dry-run.out"
[ ! -e "$LOG/ssh" ] && [ ! -e "$LOG/scp" ]
grep -qF 'copy verified packages' "$TMP/dry-run.out"
grep -qF 'file-restore: file-restore/4.2.8-2+ntfs3g1' "$TMP/dry-run.out"
grep -qF 'restore-image: restore-image/1.1.0+ntfs3g1' "$TMP/dry-run.out"
grep -qF 'meta: meta/2.2.0' "$TMP/dry-run.out"

# --check runs the packaged checker with --json for every node, continues after
# a LOST node, reports English status, and writes one JSON entry per node.
if "$ROOT/scripts/cluster-install.sh" --check --report "$TMP/check.json" > "$TMP/check.out"; then
  echo 'check unexpectedly passed with one LOST node' >&2
  exit 1
fi
grep -qF 'pve-a                    ACTIVE' "$TMP/check.out"
grep -qF 'pve-b                    LOST' "$TMP/check.out"
grep -qF 'pve-c                    ACTIVE' "$TMP/check.out"
grep -qF '/usr/sbin/pve-file-restore-ntfs3g-check --json' "$LOG/ssh"
python3 - "$TMP/check.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding='utf-8'))
assert report['mode'] == 'check'
assert [item['node'] for item in report['nodes']] == ['pve-a', 'pve-b', 'pve-c']
assert [item['status'] for item in report['nodes']] == ['ACTIVE', 'LOST', 'ACTIVE']
assert report['nodes'][1]['exit_status'] != 0
PY

# Offline input requires one release directory and an individual SHA file per
# component. It reaches the remote install path only after verification.
FROM="$TMP/from"
for component in file-restore restore-image meta; do
  mkdir -p "$FROM/$component"
  case "$component" in
    file-restore) deb='proxmox-backup-file-restore_4.2.8-2+ntfs3g1_amd64.deb' ;;
    restore-image) deb='proxmox-backup-restore-image_1.1.0+ntfs3g1_amd64.deb' ;;
    meta) deb='pve-file-restore-ntfs3g_2.2.0_all.deb' ;;
  esac
  printf '%s\n' "$deb" > "$FROM/$component/$deb"
  (cd "$FROM/$component" && sha256sum "$deb" > SHA256SUMS)
done
if "$ROOT/scripts/cluster-install.sh" --from-dir "$FROM" --hold --report "$TMP/install.json" > "$TMP/install.out"; then
  echo 'install unexpectedly passed with one LOST node' >&2
  exit 1
fi
grep -qF 'apt_flags+=(' "$LOG/remote-script-pve-a"
grep -qF 'allow-change-held-packages' "$LOG/remote-script-pve-a"
grep -qF 'apt-get update' "$LOG/remote-script-pve-a"
grep -qF 'pve-file-restore-ntfs3g-check' "$LOG/remote-script-pve-a"
[ -s "$LOG/scp" ]
python3 - "$TMP/install.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding='utf-8'))
assert report['mode'] == 'install'
assert len(report['nodes']) == 3
assert report['nodes'][1]['status'] == 'LOST'
assert report['nodes'][2]['status'] == 'ACTIVE'
PY

# A component whose listed hash does not match is rejected before SSH.
printf '%064d  proxmox-backup-file-restore_4.2.8-2+ntfs3g1_amd64.deb\n' 0 > "$FROM/file-restore/SHA256SUMS"
if "$ROOT/scripts/cluster-install.sh" --from-dir "$FROM" > "$TMP/bad.out" 2>&1; then
  echo 'checksum mismatch unexpectedly installed' >&2
  exit 1
fi
grep -q 'FAILED' "$TMP/bad.out"
