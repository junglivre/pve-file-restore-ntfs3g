#!/usr/bin/env bash
# Install the ntfs-3g File Restore packages on every online node of a PVE
# cluster. Run as root on any node of the cluster.
#
#   scripts/cluster-install.sh                 install latest stable releases
#   scripts/cluster-install.sh --check         read-only status table
#   scripts/cluster-install.sh --from-dir DIR  install verified local releases
#   scripts/cluster-install.sh --channel testing   use pre-releases (lab)
#   scripts/cluster-install.sh --dry-run       show the remote operations
#   scripts/cluster-install.sh --hold          hold upstream packages after install
#
# --from-dir requires one verified release directory per component:
#   DIR/file-restore/{proxmox-backup-file-restore_*.deb,SHA256SUMS}
#   DIR/restore-image/{proxmox-backup-restore-image_*.deb,SHA256SUMS}
#   DIR/meta/{pve-file-restore-ntfs3g_*.deb,SHA256SUMS}
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
            sed -n '2,18p' "$0"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case $CHANNEL in stable|testing) ;; *) echo "--channel must be stable or testing" >&2; exit 2 ;; esac

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

nodes_json=$(pvesh get /cluster/status --output-format json)
mapfile -t NODES < <(python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    if entry.get("type") == "node" and entry.get("online") == 1:
        print(entry["name"])
' <<<"$nodes_json")
[ "${#NODES[@]}" -gt 0 ] || { echo "no online nodes found" >&2; exit 1; }
echo "online nodes: ${NODES[*]}"

if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '%-16s %-28s %-22s %s\n' NODE FILE-RESTORE RESTORE-IMAGE STATUS
    for node in "${NODES[@]}"; do
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$node" '
            fr=$(dpkg-query -W -f '"'"'${Version}'"'"' proxmox-backup-file-restore 2>/dev/null || echo "-")
            ri=$(dpkg-query -W -f '"'"'${Version}'"'"' proxmox-backup-restore-image 2>/dev/null || echo "-")
            d=/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore
            patched=0
            [ -r "$d/proxmox-restore-daemon" ] \
                && grep -aqF "try FUSE mount using ntfs-3g" "$d/proxmox-restore-daemon" \
                && patched=1
            plugin=0
            [ -r "$d/initramfs.img" ] \
                && lsinitramfs "$d/initramfs.img" 2>/dev/null | grep -qx "usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so" \
                && plugin=1
            if [ "$patched" = 1 ] && [ "$plugin" = 1 ]; then s=ATIVO; else s=PERDIDO; fi
            echo "$fr|$ri|$s"
        ' </dev/null) || out='unreachable|unreachable|UNREACHABLE'
        IFS='|' read -r fr ri status <<<"$out"
        printf '%-16s %-28s %-22s %s\n' "$node" "$fr" "$ri" "$status"
    done
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

verify_component_dir() {
    local component=$1 directory=$2 pattern deb
    pattern="${DEB_OF[$component]}_*.deb"
    [ -d "$directory" ] || { echo "$component: release directory not found: $directory" >&2; exit 1; }
    mapfile -t debs < <(find "$directory" -maxdepth 1 -type f -name "$pattern" -printf '%f\n')
    [ "${#debs[@]}" -eq 1 ] || {
        echo "$component: expected exactly one $pattern in $directory" >&2
        exit 1
    }
    deb=${debs[0]}
    [ -f "$directory/SHA256SUMS" ] || { echo "$component: SHA256SUMS missing in $directory" >&2; exit 1; }
    (cd "$directory" && sha256sum -c SHA256SUMS)
    grep -qF "  $deb" "$directory/SHA256SUMS" || {
        echo "$component: $deb is not covered by SHA256SUMS" >&2
        exit 1
    }
}

if [ -n "$FROM_DIR" ]; then
    for component in "${COMPONENTS[@]}"; do
        source_dir="$FROM_DIR/$component"
        verify_component_dir "$component" "$source_dir"
        mkdir -p "$WORK/$component"
        cp "$source_dir"/*.deb "$source_dir/SHA256SUMS" "$WORK/$component/"
    done
else
    echo "downloading $CHANNEL releases from github.com/$REPO"
    python3 - "$REPO" "$CHANNEL" "$WORK" "${COMPONENTS[@]}" <<'EOF'
import json, os, re, subprocess, sys, urllib.request

repo, channel, work = sys.argv[1:4]
components = sys.argv[4:]
patterns = {
    "file-restore": re.compile(r"^file-restore/.+\+ntfs3g\d+$"),
    "restore-image": re.compile(r"^restore-image/.+\+ntfs3g\d+$"),
    "meta": re.compile(r"^meta/\d+\.\d+\.\d+$"),
}
api_url = os.environ.get(
    "PVE_FILE_RESTORE_RELEASES_URL",
    f"https://api.github.com/repos/{repo}/releases?per_page=100",
)
with urllib.request.urlopen(api_url) as r:
    releases = json.load(r)

for component in components:
    candidates = [r for r in releases
                  if patterns[component].match(r["tag_name"])
                  and (channel == "testing" or not r["prerelease"])]
    if not candidates:
        sys.exit(f"no {channel} release found for {component}")
    rel = candidates[0]
    assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
    debs = [n for n in assets if n.endswith(".deb")]
    if len(debs) != 1 or "SHA256SUMS" not in assets:
        sys.exit(f"release {rel['tag_name']}: expected exactly 1 .deb and SHA256SUMS, got {sorted(assets)}")
    destination = os.path.join(work, component)
    os.mkdir(destination)
    for name in (debs[0], "SHA256SUMS"):
        subprocess.run(["curl", "-fsSL", assets[name], "-o", os.path.join(destination, name)], check=True)
    print(f"{component}: {rel['tag_name']} ({'pre-release' if rel['prerelease'] else 'stable'})")
EOF
    for component in "${COMPONENTS[@]}"; do
        verify_component_dir "$component" "$WORK/$component"
    done
fi

for node in "${NODES[@]}"; do
    echo "== $node"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] verify SSH connectivity to root@$node"
        echo "[dry-run] copy verified packages to root@$node:<temporary directory>/"
        echo "[dry-run] apt-get install packages, optionally hold upstream packages, run pve-file-restore-ntfs3g-check"
        continue
    fi

    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$node" true </dev/null
    remote_dir=$(ssh -o BatchMode=yes "root@$node" mktemp -d </dev/null)
    if ! scp -q "$WORK"/*/*.deb "root@$node:$remote_dir/"; then
        ssh -o BatchMode=yes "root@$node" rm -rf "$remote_dir" </dev/null || true
        exit 1
    fi
    ssh -o BatchMode=yes "root@$node" bash -s -- "$remote_dir" "$HOLD" "$HELD_PACKAGES" </dev/null <<'EOF'
set -Eeuo pipefail
remote_dir=$1
hold_requested=$2
held_packages=$3
trap 'rm -rf "$remote_dir"' EXIT

apt_flags=(-y)
if [ "$hold_requested" = 1 ]; then
    for package in $held_packages; do
        if apt-mark showhold | grep -qxF "$package"; then
            apt_flags+=(--allow-change-held-packages)
            break
        fi
    done
fi
apt-get install "${apt_flags[@]}" "$remote_dir"/*.deb
if [ "$hold_requested" = 1 ]; then
    apt-mark hold $held_packages
fi
pve-file-restore-ntfs3g-check
EOF
done

echo "done. Verify with: $0 --check"
