#!/usr/bin/env bash
# Prove a clean Debian 13 install resolves every node package from MasterMind.
set -Eeuo pipefail

usage() {
    echo "usage: $0 <stable|testing>" >&2
    exit 2
}
[ "$#" -eq 1 ] || usage
channel=$1
case $channel in stable|testing) ;; *) usage ;; esac

log=$(mktemp)
trap 'rm -f "$log"' EXIT
docker_status=0
tee_status=0
if docker run --rm -i --pull=missing debian:13 bash -s -- "$channel" <<'EOF' 2>&1 | tee "$log"
set -Eeuo pipefail
channel=$1
export DEBIAN_FRONTEND=noninteractive

step() {
    printf 'LAB STEP: %s\n' "$1"
}

step 'update the clean Debian package index'
apt-get update
step 'install bootstrap tools'
# cpio: the upstream proxmox-backup-file-restore postinst rebuilds the
# initramfs cache with it but does not depend on it (PVE nodes always have it).
apt-get install -y --no-install-recommends ca-certificates curl gnupg cpio
install -d -m 0755 /etc/apt/keyrings

step 'install and configure the MasterMind archive key'
mastermind_key=/etc/apt/keyrings/mastermind-archive.gpg
curl -fsSL https://apt.mastermindti.cloud/mastermind-archive.gpg \
    | gpg --dearmor --yes --output "$mastermind_key"
cat >/etc/apt/sources.list.d/mastermind.list <<SOURCE
deb [signed-by=$mastermind_key] https://apt.mastermindti.cloud/debian trixie $channel
SOURCE

step 'install and verify the Proxmox archive key'
proxmox_key=/etc/apt/keyrings/proxmox-archive-keyring-trixie.gpg
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o "$proxmox_key"
printf '%s  %s\n' \
    136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45 \
    "$proxmox_key" | sha256sum -c -
cat >/etc/apt/sources.list.d/proxmox.list <<SOURCE
deb [signed-by=$proxmox_key] http://download.proxmox.com/debian/pve trixie pve-no-subscription
SOURCE

step 'update package indexes from both archives'
apt-get update
step 'install mastermind-apt-config'
apt-get install -y --no-install-recommends mastermind-apt-config
# The package ships its own source (Signed-By its keyring); keeping the
# bootstrap list next to it makes apt refuse both ("Conflicting values set
# for option Signed-By"). Drop the bootstrap and let the package pick the
# channel, as a real node would.
rm -f /etc/apt/sources.list.d/mastermind.list "$mastermind_key"
step "select the MasterMind $channel component"
mastermind-apt-channel "$channel"
apt-get update
step 'install pve-file-restore-ntfs3g'
apt-get install -y --no-install-recommends pve-file-restore-ntfs3g

step 'record policy and verify MasterMind origins'
report=/tmp/pve-file-restore-apt-report.txt
: >"$report"
packages=(pve-file-restore-ntfs3g proxmox-backup-file-restore proxmox-backup-restore-image)
for package in "${packages[@]}"; do
    {
        printf '\n== apt-cache policy %s ==\n' "$package"
        apt-cache policy "$package"
        printf 'installed=%s\n' "$(dpkg-query -W -f '${Version}' "$package")"
    } >>"$report"
    installed=$(dpkg-query -W -f '${Version}' "$package")
    expected=$(apt-cache policy "$package" | awk '$1 == "Candidate:" { print $2; exit }')
    [ -n "$expected" ] && [ "$expected" != '(none)' ] || {
        echo "no APT candidate for $package" >&2
        exit 1
    }
    [ "$installed" = "$expected" ] || {
        echo "$package installed $installed, expected $expected" >&2
        exit 1
    }
    if ! apt-cache policy "$package" | awk -v version="$installed" '
        $1 == "***" && $2 == version { selected=1; next }
        selected && /apt\.mastermindti\.cloud/ { found=1 }
        selected && $1 == "***" { exit }
        END { exit(found ? 0 : 1) }
    '; then
        echo "$package $installed did not come from MasterMind APT" >&2
        exit 1
    fi
done
cat "$report"
printf 'APT-CLEAN-INSTALL: PASS channel=%s\n' "$channel"
EOF
then
    pipeline_status=${PIPESTATUS[*]}
else
    pipeline_status=${PIPESTATUS[*]}
fi
read -r docker_status tee_status <<<"$pipeline_status"
[ "$docker_status" -eq 0 ] || exit "$docker_status"
[ "$tee_status" -eq 0 ] || exit "$tee_status"
marker="APT-CLEAN-INSTALL: PASS channel=$channel"
if ! grep -qxF "$marker" "$log"; then
    echo "apt-clean-install: missing success marker: $marker" >&2
    exit 1
fi
