#!/usr/bin/env bash
# Runs inside the disposable Debian 13 Docker container invoked by build.sh.
set -Eeuo pipefail

source /project/scripts/versions.sh

export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS=nocheck

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git build-essential devscripts equivs lintian \
    autoconf automake libtool pkg-config ntfs-3g-dev python3-sphinx

curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -o /usr/share/keyrings/proxmox-release-trixie.gpg
cat >/etc/apt/sources.list.d/proxmox-devel.list <<'EOF'
deb [signed-by=/usr/share/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/devel trixie main
EOF
apt-get update

clone_pinned() {
    local repository=$1 branch=$2 commit=$3 destination=$4
    git clone --depth 1 --branch "$branch" "$repository" "$destination"
    test "$(git -C "$destination" rev-parse HEAD)" = "$commit" || {
        echo "Pinned revision mismatch for $repository" >&2
        echo "Expected: $commit" >&2
        echo "Actual:   $(git -C "$destination" rev-parse HEAD)" >&2
        exit 1
    }
}

build_dependencies() {
    local source_dir=$1
    (
        cd "$source_dir"
        mk-build-deps -i --tool 'apt-get --no-install-recommends -y' debian/control
    )
}

rm -rf /work/src
mkdir -p /work/src /out

clone_pinned "$PBS_REPOSITORY" "$PBS_BRANCH" "$PBS_COMMIT" /work/src/proxmox-backup
patch -d /work/src/proxmox-backup -p1 < /project/patches/proxmox-backup-ntfs3g-fallback.patch
build_dependencies /work/src/proxmox-backup
(
    cd /work/src/proxmox-backup
    make deb-nodoc
    install -m 0644 "proxmox-backup-file-restore_${PBS_VERSION}_amd64.deb" /out/
    # Free the large Rust build tree before building the restore kernel.
    make clean-deb
)

clone_pinned "$RESTORE_IMAGE_REPOSITORY" "$RESTORE_IMAGE_BRANCH" "$RESTORE_IMAGE_COMMIT" \
    /work/src/proxmox-backup-restore-image
clone_pinned "$DEDUP_PLUGIN_REPOSITORY" "$DEDUP_PLUGIN_BRANCH" "$DEDUP_PLUGIN_COMMIT" \
    /work/src/ntfs-3g-dedup-plugin
mkdir -p /work/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin
git -C /work/src/ntfs-3g-dedup-plugin archive --format=tar HEAD \
    | tar -x -C /work/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin
patch -d /work/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin -p1 \
    < /project/patches/ntfs-3g-dedup-plugin-fuse3.patch
patch -d /work/src/proxmox-backup-restore-image -p1 \
    < /project/patches/proxmox-backup-restore-image-ntfs3g.patch
build_dependencies /work/src/proxmox-backup-restore-image
(
    cd /work/src/proxmox-backup-restore-image
    make deb
    install -m 0644 "proxmox-backup-restore-image_${RESTORE_IMAGE_VERSION}_amd64.deb" /out/
)

cd /out
sha256sum \
    "proxmox-backup-file-restore_${PBS_VERSION}_amd64.deb" \
    "proxmox-backup-restore-image_${RESTORE_IMAGE_VERSION}_amd64.deb" \
    > SHA256SUMS

check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
dpkg-deb -x "proxmox-backup-restore-image_${RESTORE_IMAGE_VERSION}_amd64.deb" "$check_dir"
initramfs="$check_dir/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
lsinitramfs "$initramfs" | grep -qx 'usr/bin/ntfs-3g'
lsinitramfs "$initramfs" | grep -qx 'usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so'

echo "Build complete. Assets written to /out"
