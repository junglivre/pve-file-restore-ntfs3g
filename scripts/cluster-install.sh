#!/usr/bin/env bash
# Install the ntfs-3g File Restore packages on every online node of a PVE
# cluster. Run as root on any node of the cluster.
#
#   scripts/cluster-install.sh                 install latest stable releases
#   scripts/cluster-install.sh --check         read-only status table
#   scripts/cluster-install.sh --from-dir DIR  install .deb files from DIR (no internet)
#   scripts/cluster-install.sh --channel testing   use pre-releases (lab)
#   scripts/cluster-install.sh --dry-run       show what would happen
#   scripts/cluster-install.sh --hold          apt-mark hold the two upstream
#                                              packages after installing
#
# Idempotent: re-running installs the same packages again (a no-op for apt)
# and re-runs the verification.
#
# NOTE: without --hold, a plain `apt upgrade` replaces the patched packages
# with the official ones. See docs/standalone.md.
set -Eeuo pipefail

REPO='junglivre/pve-file-restore-ntfs3g'
COMPONENTS=(file-restore restore-image meta)
declare -A DEB_OF=(
    [file-restore]=proxmox-backup-file-restore
    [restore-image]=proxmox-backup-restore-image
    [meta]=pve-file-restore-ntfs3g
)
HELD_PACKAGES='proxmox-backup-file-restore proxmox-backup-restore-image'

CHECK_ONLY=0
FROM_DIR=''
CHANNEL=stable
DRY_RUN=0
HOLD=0

while [ $# -gt 0 ]; do
    case $1 in
        --check) CHECK_ONLY=1; shift ;;
        --from-dir) FROM_DIR=$2; shift 2 ;;
        --channel) CHANNEL=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --hold) HOLD=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case $CHANNEL in stable|testing) ;; *) echo "--channel must be stable or testing" >&2; exit 2 ;; esac

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# --- online nodes -----------------------------------------------------------
nodes_json=$(pvesh get /cluster/status --output-format json)
mapfile -t NODES < <(python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    if entry.get("type") == "node" and entry.get("online") == 1:
        print(entry["name"])
' <<<"$nodes_json")
[ "${#NODES[@]}" -gt 0 ] || { echo "no online nodes found" >&2; exit 1; }
echo "online nodes: ${NODES[*]}"

# --- --check: read-only status table ----------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '%-16s %-28s %-22s %s\n' NODE FILE-RESTORE RESTORE-IMAGE STATUS
    for node in "${NODES[@]}"; do
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$node" '
            fr=$(dpkg-query -W -f "${Version}" proxmox-backup-file-restore 2>/dev/null || echo "-")
            ri=$(dpkg-query -W -f "${Version}" proxmox-backup-restore-image 2>/dev/null || echo "-")
            d=/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore
            patched=0
            [ -r "$d/proxmox-restore-daemon" ] \
                && strings "$d/proxmox-restore-daemon" | grep -qF "try FUSE mount using ntfs-3g" \
                && patched=1
            plugin=0
            [ -r "$d/initramfs.img" ] \
                && lsinitramfs "$d/initramfs.img" 2>/dev/null | grep -q "ntfs-plugin-80000013" \
                && plugin=1
            if [ "$patched" = 1 ] && [ "$plugin" = 1 ]; then s=ATIVO; else s=PERDIDO; fi
            echo "$fr|$ri|$s"
        ' </dev/null) || out='unreachable|unreachable|UNREACHABLE'
        IFS='|' read -r fr ri status <<<"$out"
        printf '%-16s %-28s %-22s %s\n' "$node" "$fr" "$ri" "$status"
    done
    exit 0
fi

# --- obtain the packages ----------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "$FROM_DIR" ]; then
    for component in "${COMPONENTS[@]}"; do
        deb=$(find "$FROM_DIR" -maxdepth 1 -name "${DEB_OF[$component]}_*.deb" | head -1)
        [ -n "$deb" ] || { echo "${DEB_OF[$component]}_*.deb not found in $FROM_DIR" >&2; exit 1; }
        cp "$deb" "$WORK/"
    done
else
    echo "downloading $CHANNEL releases from github.com/$REPO"
    python3 - "$REPO" "$CHANNEL" "$WORK" "${COMPONENTS[@]}" <<'EOF'
import json, os, subprocess, sys, urllib.request

repo, channel, work = sys.argv[1:4]
components = sys.argv[4:]

with urllib.request.urlopen(
        f"https://api.github.com/repos/{repo}/releases?per_page=100") as r:
    releases = json.load(r)

for component in components:
    candidates = [r for r in releases
                  if r["tag_name"].startswith(f"{component}/")
                  and (channel == "testing" or not r["prerelease"])]
    if not candidates:
        sys.exit(f"no {channel} release found for {component}")
    rel = candidates[0]  # API returns newest first
    assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
    debs = [n for n in assets if n.endswith(".deb")]
    if len(debs) != 1 or "SHA256SUMS" not in assets:
        sys.exit(f"release {rel['tag_name']}: expected exactly 1 .deb and SHA256SUMS, got {sorted(assets)}")
    for name in (debs[0], "SHA256SUMS"):
        subprocess.run(["curl", "-fsSL", assets[name], "-o", os.path.join(work, name)],
                       check=True)
    print(f"{component}: {rel['tag_name']} ({'pre-release' if rel['prerelease'] else 'stable'})")
EOF
    (cd "$WORK" && sha256sum -c SHA256SUMS --ignore-missing)
    # every downloaded .deb must be covered by the checksums
    for deb in "$WORK"/*.deb; do
        grep -q " $(basename "$deb")\$" "$WORK/SHA256SUMS" || {
            echo "$(basename "$deb") not in SHA256SUMS" >&2
            exit 1
        }
    done
fi

# --- install on every node --------------------------------------------------
for node in "${NODES[@]}"; do
    echo "== $node"
    run ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$node" true </dev/null
    remote_dir=$(ssh -o BatchMode=yes "root@$node" mktemp -d </dev/null)
    run scp -q "$WORK"/*.deb "root@$node:$remote_dir/"
    run ssh -o BatchMode=yes "root@$node" bash -s </dev/null <<EOF
set -e
apt-get install -y $remote_dir/*.deb
if [ "$HOLD" = 1 ]; then
    apt-mark hold $HELD_PACKAGES
fi
pve-file-restore-ntfs3g-check
rm -rf $remote_dir
EOF
done

echo "done. Verify with: $0 --check"
