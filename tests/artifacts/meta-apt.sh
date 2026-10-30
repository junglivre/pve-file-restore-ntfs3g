#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <artifacts-dir>" >&2; exit 2; }
artifacts=$1
readonly PROXMOX_KEYRING_URL='https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg'
readonly PROXMOX_KEYRING_SHA256='136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45'

find_one() {
    local directory=$1 pattern=$2
    local matches=()
    mapfile -t matches < <(find "$directory" -maxdepth 1 -type f -name "$pattern" -print)
    [ "${#matches[@]}" -eq 1 ] || { echo "expected one $pattern in $directory" >&2; exit 1; }
    printf '%s\n' "${matches[0]}"
}

meta=$(find_one "$artifacts/meta" 'pve-file-restore-ntfs3g_*.deb')
fr=$(find_one "$artifacts/file-restore" 'proxmox-backup-file-restore_*.deb')
ri=$(find_one "$artifacts/restore-image" 'proxmox-backup-restore-image_*.deb')
fr_version=$(dpkg-deb -f "$fr" Version)
ri_version=$(dpkg-deb -f "$ri" Version)
fr_upstream=${fr_version%+ntfs3g*}
ri_upstream=${ri_version%+ntfs3g*}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends apt-utils ca-certificates curl dpkg-dev gnupg

keyring=/usr/share/keyrings/proxmox-archive-keyring-trixie.gpg
curl -fsSL "$PROXMOX_KEYRING_URL" -o "$keyring"
key_hash=$(sha256sum "$keyring")
key_hash=${key_hash%% *}
[ "$key_hash" = "$PROXMOX_KEYRING_SHA256" ] || {
    echo 'Proxmox archive key digest mismatch' >&2
    exit 1
}
cat >/etc/apt/sources.list.d/proxmox.list <<'EOF'
deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF
apt-get update -qq

repo_root=$(mktemp -d)
gnupg_home="$repo_root/gnupg"
mkdir -m 0700 "$gnupg_home"
export GNUPGHOME="$gnupg_home"
gpg --batch --quick-generate-key 'local apt test <local@example.invalid>' rsa2048 sign 0
gpg --batch --export > /usr/share/keyrings/local-apt-test.gpg

mkdir -p "$repo_root/official" "$repo_root/patched"
(
    cd "$repo_root/official"
    apt-get download "proxmox-backup-file-restore=$fr_upstream" \
        "proxmox-backup-restore-image=$ri_upstream"
)
cp "$fr" "$ri" "$meta" "$repo_root/patched/"

make_repo() {
    local repo=$1
    (cd "$repo" && dpkg-scanpackages . /dev/null > Packages && gzip -9c Packages > Packages.gz)
    (cd "$repo" && apt-ftparchive release . > Release && gpg --batch --yes --clearsign \
        --output InRelease Release)
}
make_repo "$repo_root/official"
make_repo "$repo_root/patched"
cat >/etc/apt/sources.list.d/local-apt-test.list <<EOF
deb [signed-by=/usr/share/keyrings/local-apt-test.gpg] file:$repo_root/official ./
EOF
apt-get update -qq

negative_log="$repo_root/negative.log"
if (cd / && apt-get install -y --no-install-recommends "$meta") >"$negative_log" 2>&1; then
    echo 'metapackage installed with only official packages' >&2
    exit 1
fi
grep -qF 'proxmox-backup-file-restore-ntfs3g' "$negative_log"
grep -qF 'proxmox-backup-restore-image-ntfs3g' "$negative_log"
echo 'meta negative dependency check passed: both virtual package names were unmet'

cat >>/etc/apt/sources.list.d/local-apt-test.list <<EOF
deb [signed-by=/usr/share/keyrings/local-apt-test.gpg] file:$repo_root/patched ./
EOF
apt-get update -qq
apt-get install -y --no-install-recommends pve-file-restore-ntfs3g
echo 'meta positive dependency check passed: patched package set installed'
