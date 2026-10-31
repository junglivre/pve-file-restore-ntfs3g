#!/usr/bin/env bash
# Install and verify the ntfs-3g File Restore packages on every online node.
# Run as root on any node of the PVE cluster.
#
#   scripts/cluster-install.sh                 install latest stable releases
#   scripts/cluster-install.sh --check         verify every online node
#   scripts/cluster-install.sh --from-dir DIR  install verified local releases
#   scripts/cluster-install.sh --channel testing   use pre-releases (lab)
#   scripts/cluster-install.sh --dry-run       show the remote operations
#   scripts/cluster-install.sh --hold          hold upstream packages after install
#   scripts/cluster-install.sh --report FILE   write one JSON result per node
#
# --from-dir requires one verified release directory per component:
#   DIR/file-restore/{proxmox-backup-file-restore_*.deb,SHA256SUMS}
#   DIR/restore-image/{proxmox-backup-restore-image_*.deb,SHA256SUMS}
#   DIR/meta/{pve-file-restore-ntfs3g_*.deb,SHA256SUMS}
set -Eeuo pipefail

# shellcheck disable=SC1078,SC1079,SC2016
# Reason: remote shell quoting preserves the literal dpkg format string.

REPO='junglivre/pve-file-restore-ntfs3g'
COMPONENTS=(file-restore restore-image meta)
declare -A DEB_OF=(
    [file-restore]=proxmox-backup-file-restore
    [restore-image]=proxmox-backup-restore-image
    [meta]=pve-file-restore-ntfs3g
)
HELD_PACKAGES=(proxmox-backup-file-restore proxmox-backup-restore-image)

CHECK_ONLY=0
FROM_DIR=''
CHANNEL=stable
DRY_RUN=0
HOLD=0
REPORT=''

usage() {
    cat <<'EOF'
usage: scripts/cluster-install.sh [OPTIONS]

Install and verify the patched File Restore packages on every online PVE node.

Options:
  --check                   verify nodes without installing packages
  --from-dir DIR            use checksum-verified local component releases
  --channel stable|testing  select the GitHub release channel (default: stable)
  --dry-run                 show install operations without contacting nodes
  --hold                    hold the two patched upstream packages after install
  --report FILE             write a JSON report with one result per node
  -h, --help                show this usage text
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --check) CHECK_ONLY=1; shift ;;
        --from-dir)
            [ "$#" -ge 2 ] || { echo '--from-dir requires a directory' >&2; exit 2; }
            FROM_DIR=$2
            shift 2
            ;;
        --channel)
            [ "$#" -ge 2 ] || { echo '--channel requires stable or testing' >&2; exit 2; }
            CHANNEL=$2
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --hold) HOLD=1; shift ;;
        --report)
            [ "$#" -ge 2 ] || { echo '--report requires a file' >&2; exit 2; }
            REPORT=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case $CHANNEL in stable|testing) ;; *) echo '--channel must be stable or testing' >&2; exit 2 ;; esac

[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 1; }

nodes_json=''
nodes_status=0
if nodes_json=$(pvesh get /cluster/status --output-format json); then
    nodes_status=0
else
    nodes_status=$?
fi
[ "$nodes_status" -eq 0 ] || { echo 'could not read cluster status' >&2; exit "$nodes_status"; }

nodes_text=''
nodes_status=0
if nodes_text=$(python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    if entry.get("type") == "node" and entry.get("online") == 1:
        print(entry["name"], entry.get("ip") or entry["name"])
' <<<"$nodes_json"); then
    nodes_status=0
else
    nodes_status=$?
fi
[ "$nodes_status" -eq 0 ] || { echo 'cluster status was not valid JSON' >&2; exit 1; }
NODES=()
declare -A NODE_ADDR=()
while read -r node_name node_addr; do
    [ -n "$node_name" ] || continue
    NODES+=("$node_name")
    NODE_ADDR[$node_name]=$node_addr
done <<<"$nodes_text"
if [ "${#NODES[@]}" -eq 0 ]; then
    echo 'no online nodes found' >&2
    exit 1
fi
echo "online nodes: ${NODES[*]}"

# PVE 9 keeps each node's host key in /etc/pve/nodes/<node>/ssh_known_hosts
# and connects with HostKeyAlias=<node> (PVE::SSHInfo); a plain
# `ssh root@<node>` fails host key verification there.
PVE_NODES_DIR=${PVE_NODES_DIR:-/etc/pve/nodes}
node_ssh_opts() {
    printf '%s\n' -o BatchMode=yes -o ConnectTimeout=5 -o "HostKeyAlias=$1" \
        -o "UserKnownHostsFile=$PVE_NODES_DIR/$1/ssh_known_hosts" \
        -o GlobalKnownHostsFile=none
}
node_ssh() {
    local node=$1 opts=()
    shift
    mapfile -t opts < <(node_ssh_opts "$node")
    ssh -e none "${opts[@]}" "root@${NODE_ADDR[$node]}" "$@"
}
node_scp_to() {
    local node=$1 destination=$2 opts=()
    shift 2
    mapfile -t opts < <(node_ssh_opts "$node")
    scp -q "${opts[@]}" "$@" "root@${NODE_ADDR[$node]}:$destination"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/nodes"

record_node() {
    local index=$1 node=$2 status=$3 exit_status=$4 stdout_file=$5 stderr_file=$6
    local node_dir="$WORK/nodes/$index"
    mkdir -p "$node_dir"
    printf '%s\n' "$node" >"$node_dir/node"
    printf '%s\n' "$status" >"$node_dir/status"
    printf '%s\n' "$exit_status" >"$node_dir/exit_status"
    cp -- "$stdout_file" "$node_dir/stdout"
    cp -- "$stderr_file" "$node_dir/stderr"
    printf '%-24s %s\n' "$node" "$status"
}

check_json_is_ok() {
    local file=$1
    python3 - "$file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        value = json.load(stream)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if value.get("ok") is True else 1)
PY
}

write_report() {
    [ -n "$REPORT" ] || return 0
    python3 - "$REPORT" "$WORK/nodes" "$CHECK_ONLY" <<'PY'
import json
import os
import sys
from pathlib import Path

destination = Path(sys.argv[1])
nodes_dir = Path(sys.argv[2])
check_only = sys.argv[3] == "1"
entries = []
for directory in sorted(nodes_dir.iterdir(), key=lambda item: int(item.name)):
    node = (directory / "node").read_text(encoding="utf-8").rstrip("\n")
    status = (directory / "status").read_text(encoding="utf-8").rstrip("\n")
    exit_status = int((directory / "exit_status").read_text(encoding="utf-8"))
    raw = (directory / "stdout").read_text(encoding="utf-8").strip()
    check = None
    if raw:
        try:
            check = json.loads(raw)
        except json.JSONDecodeError:
            check = None
    entries.append({
        "node": node,
        "status": status,
        "exit_status": exit_status,
        "check": check,
    })

report = {
    "mode": "check" if check_only else "install",
    "nodes": entries,
}
destination.parent.mkdir(parents=True, exist_ok=True)
temporary = destination.with_name(destination.name + ".tmp")
temporary.write_text(json.dumps(report, sort_keys=True) + "\n", encoding="utf-8")
os.replace(temporary, destination)
PY
}

verify_component_dir() {
    local component=$1 directory=$2 pattern deb
    local -a debs sums
    pattern="${DEB_OF[$component]}_*.deb"
    [ -d "$directory" ] || { echo "$component: release directory not found: $directory" >&2; exit 1; }
    mapfile -t debs < <(find "$directory" -maxdepth 1 -type f -name "$pattern" -printf '%f\n')
    [ "${#debs[@]}" -eq 1 ] || {
        echo "$component: expected exactly one $pattern in $directory" >&2
        exit 1
    }
    deb=${debs[0]}
    [ -f "$directory/SHA256SUMS" ] || { echo "$component: SHA256SUMS missing in $directory" >&2; exit 1; }
    mapfile -t sums < <(awk 'NF == 2 { print $2 }' "$directory/SHA256SUMS")
    if [ "${#sums[@]}" -ne 1 ] || [ "${sums[0]}" != "$deb" ]; then
        echo "$component: SHA256SUMS must cover only $deb" >&2
        exit 1
    fi
    (cd "$directory" && sha256sum -c SHA256SUMS)
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    for index in "${!NODES[@]}"; do
        node=${NODES[$index]}
        stdout_file="$WORK/check-$index.out"
        stderr_file="$WORK/check-$index.err"
        node_status=0
        if node_ssh "$node" \
            /usr/sbin/pve-file-restore-ntfs3g-check --json </dev/null \
            >"$stdout_file" 2>"$stderr_file"; then
            node_status=0
        else
            node_status=$?
        fi
        if [ "$node_status" -eq 0 ] && check_json_is_ok "$stdout_file"; then
            node_state=ACTIVE
        else
            node_state=LOST
        fi
        record_node "$index" "$node" "$node_state" "$node_status" \
            "$stdout_file" "$stderr_file"
    done
    write_report
    exit_status=0
    for index in "${!NODES[@]}"; do
        if [ "$(cat "$WORK/nodes/$index/status")" != ACTIVE ]; then
            exit_status=1
        fi
    done
    exit "$exit_status"
fi

if [ -n "$FROM_DIR" ]; then
    for component in "${COMPONENTS[@]}"; do
        source_dir="$FROM_DIR/$component"
        verify_component_dir "$component" "$source_dir"
        mkdir -p "$WORK/$component"
        deb=$(find "$source_dir" -maxdepth 1 -type f -name "${DEB_OF[$component]}_*.deb" -printf '%f\n')
        cp -- "$source_dir/$deb" "$WORK/$component/$deb"
    done
else
    echo "downloading highest $CHANNEL releases from github.com/$REPO"
    python3 - "$REPO" "$CHANNEL" "$WORK" "${COMPONENTS[@]}" <<'PY'
import json
import os
import re
import subprocess
import sys
import urllib.request

repo, channel, work = sys.argv[1:4]
components = sys.argv[4:]
patterns = {
    "file-restore": re.compile(r"^file-restore/(.+\+ntfs3g[0-9]+)$"),
    "restore-image": re.compile(r"^restore-image/(.+\+ntfs3g[0-9]+)$"),
    "meta": re.compile(r"^meta/([0-9]+\.[0-9]+\.[0-9]+)$"),
}
api_url = os.environ.get(
    "PVE_FILE_RESTORE_RELEASES_URL",
    f"https://api.github.com/repos/{repo}/releases?per_page=100",
)
with urllib.request.urlopen(api_url) as response:
    releases = json.load(response)

def higher(left, right):
    return subprocess.run(
        ["dpkg", "--compare-versions", left, "gt", right],
        check=False,
    ).returncode == 0

for component in components:
    candidates = []
    for release in releases:
        match = patterns[component].match(release["tag_name"])
        if not match or (channel == "stable" and release["prerelease"]):
            continue
        candidates.append((match.group(1), release))
    if not candidates:
        raise SystemExit(f"no {channel} release found for {component}")

    version, release = candidates[0]
    for candidate_version, candidate_release in candidates[1:]:
        if higher(candidate_version, version):
            version, release = candidate_version, candidate_release
    assets = {asset["name"]: asset["browser_download_url"] for asset in release["assets"]}
    debs = [name for name in assets if name.endswith(".deb")]
    if len(debs) != 1 or "SHA256SUMS" not in assets:
        raise SystemExit(
            f"release {release['tag_name']}: expected exactly 1 .deb and SHA256SUMS, got {sorted(assets)}"
        )
    destination = os.path.join(work, component)
    os.mkdir(destination)
    for name in (debs[0], "SHA256SUMS"):
        subprocess.run(
            ["curl", "-fsSL", assets[name], "-o", os.path.join(destination, name)],
            check=True,
        )
    print(f"{component}: {release['tag_name']} ({'pre-release' if release['prerelease'] else 'stable'})")
PY
    for component in "${COMPONENTS[@]}"; do
        verify_component_dir "$component" "$WORK/$component"
    done
fi

if [ "$DRY_RUN" -eq 1 ]; then
    for index in "${!NODES[@]}"; do
        node=${NODES[$index]}
        echo "$node: ACTIVE"
        echo "[dry-run] verify SSH connectivity to root@$node"
        echo "[dry-run] copy verified packages to root@$node:<temporary directory>/"
        echo "[dry-run] apt-get update, install packages, optionally hold packages, run the checker"
        mkdir -p "$WORK/nodes/$index"
        printf '%s\n' "$node" >"$WORK/nodes/$index/node"
        printf '%s\n' ACTIVE >"$WORK/nodes/$index/status"
        printf '%s\n' 0 >"$WORK/nodes/$index/exit_status"
        : >"$WORK/nodes/$index/stdout"
        : >"$WORK/nodes/$index/stderr"
    done
    write_report
    exit 0
fi

for index in "${!NODES[@]}"; do
    node=${NODES[$index]}
    stdout_file="$WORK/install-$index.out"
    stderr_file="$WORK/install-$index.err"
    : >"$stdout_file"
    : >"$stderr_file"
    node_status=0
    remote_dir=''
    if remote_dir=$(node_ssh "$node" mktemp -d </dev/null); then
        node_status=0
    else
        node_status=$?
    fi
    if [ "$node_status" -eq 0 ]; then
        if node_scp_to "$node" "$remote_dir/" "$WORK"/*/*.deb >>"$stdout_file" 2>>"$stderr_file"; then
            node_status=0
        else
            node_status=$?
        fi
    fi
    if [ "$node_status" -eq 0 ]; then
        # ssh joins its arguments into one remote command line, so quote each
        # one; otherwise the package list is split and only the first is held.
        if node_ssh "$node" bash -s -- "$(printf '%q' "$remote_dir")" "$HOLD" \
            "$(printf '%q' "${HELD_PACKAGES[*]}")" >"$stdout_file" 2>"$stderr_file" <<'EOF'
set -Eeuo pipefail
remote_dir=$1
hold_requested=$2
read -r -a held_packages <<<"$3"
trap 'rm -rf "$remote_dir"' EXIT

apt-get update >&2
apt_flags=(-y)
if [ "$hold_requested" = 1 ]; then
    for package in "${held_packages[@]}"; do
        held=$(apt-mark showhold)
        if grep -qxF "$package" <<<"$held"; then
            apt_flags+=(--allow-change-held-packages)
            break
        fi
    done
fi
apt-get install "${apt_flags[@]}" "$remote_dir"/*.deb >&2
if [ "$hold_requested" = 1 ]; then
    apt-mark hold "${held_packages[@]}" >&2
fi
/usr/sbin/pve-file-restore-ntfs3g-check --json
EOF
        then
            node_status=0
        else
            node_status=$?
        fi
    fi
    if [ -n "$remote_dir" ]; then
        node_ssh "$node" rm -rf "$(printf '%q' "$remote_dir")" </dev/null \
            >>"$stderr_file" 2>&1 || true
    fi
    if [ "$node_status" -eq 0 ] && check_json_is_ok "$stdout_file"; then
        node_state=ACTIVE
    else
        node_state=LOST
    fi
    record_node "$index" "$node" "$node_state" "$node_status" \
        "$stdout_file" "$stderr_file"
done

write_report
exit_status=0
for index in "${!NODES[@]}"; do
    if [ "$(cat "$WORK/nodes/$index/status")" != ACTIVE ]; then
        exit_status=1
    fi
done
if [ "$exit_status" -ne 0 ]; then
    echo 'one or more nodes are LOST' >&2
    exit 1
fi
echo 'all online nodes are ACTIVE'
echo 'done. Verify with: scripts/cluster-install.sh --check'
