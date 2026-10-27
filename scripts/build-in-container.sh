#!/usr/bin/env bash
# Runs inside the disposable Debian 13 container started by build.sh.
# Builds the component named by BUILD_COMPONENT, exactly as upstream.lock
# describes it.
set -Eeuo pipefail

# Paths: /project, /work and /out are the mount points used by build.sh; CI
# overrides them with PROJECT_DIR/WORK_DIR/OUTPUT_DIR.
PROJECT_DIR=${PROJECT_DIR:-/project}
WORK_DIR=${WORK_DIR:-/work}
OUTPUT_DIR=${OUTPUT_DIR:-/out}

# shellcheck source=lib-lock.sh
source "$PROJECT_DIR/scripts/lib-lock.sh"
cd "$PROJECT_DIR"

COMPONENT=${BUILD_COMPONENT:?BUILD_COMPONENT is required}

mkdir -p "$WORK_DIR/src" "$WORK_DIR/pkg" "$OUTPUT_DIR"

export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS=nocheck

PBS_REPOSITORY='https://git.proxmox.com/git/proxmox-backup.git'
RESTORE_IMAGE_REPOSITORY='https://git.proxmox.com/git/proxmox-backup-restore-image.git'
DEDUP_PLUGIN_REPOSITORY='https://github.com/smx-smx/ntfs-3g-dedup-plugin.git'

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git build-essential devscripts equivs lintian \
    autoconf automake libtool pkg-config ntfs-3g-dev libfuse3-dev python3-sphinx

curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -o /usr/share/keyrings/proxmox-release-trixie.gpg
cat >/etc/apt/sources.list.d/proxmox-devel.list <<'EOF'
deb [signed-by=/usr/share/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/devel trixie main
EOF
apt-get update

# Record the exact state of the Proxmox devel repository in the build log, so
# a build can be traced back to the repository snapshot it used.
echo "== proxmox devel repository snapshot =="
curl -fsSL http://download.proxmox.com/debian/devel/dists/trixie/InRelease \
    -o $WORK_DIR/proxmox-devel-InRelease
grep -E '^(Date|Valid-Until):' $WORK_DIR/proxmox-devel-InRelease || true
sha256sum $WORK_DIR/proxmox-devel-InRelease

verify_patch_hash() {
    local component=$1 patch=$2
    local expected actual
    expected=$(lock_field "$component" patches_sha256)
    [ "$expected" != '-' ] || return 0
    actual=$(sha256sum "$PROJECT_DIR/$patch" | awk '{print $1}')
    [ "$actual" = "$expected" ] || {
        echo "patch hash mismatch for $component ($patch)" >&2
        echo "expected: $expected (upstream.lock)" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

# Full clone + checkout by commit. git.proxmox.com ignores --filter and a
# pinned branch breaks as soon as the branch moves, so the commit in
# upstream.lock is the only reference.
clone_pinned() {
    local repository=$1 commit=$2 destination=$3
    rm -rf "$destination"
    git clone --quiet "$repository" "$destination"
    # The pinned commit may live outside any branch (e.g. the dedup plugin's
    # unmerged fix); fetch it by SHA as a fallback.
    if ! git -C "$destination" checkout --quiet "$commit" 2>/dev/null; then
        git -C "$destination" fetch --quiet origin "$commit"
        git -C "$destination" checkout --quiet "$commit"
    fi
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

build_file_restore() {
    local version commit
    version=$(lock_field file-restore version)
    commit=$(lock_field file-restore commit)
    verify_patch_hash file-restore patches/proxmox-backup-ntfs3g-fallback.patch

    clone_pinned "$PBS_REPOSITORY" "$commit" $WORK_DIR/src/proxmox-backup
    patch -d $WORK_DIR/src/proxmox-backup -p1 < $PROJECT_DIR/patches/proxmox-backup-ntfs3g-fallback.patch
    build_dependencies $WORK_DIR/src/proxmox-backup
    (
        cd $WORK_DIR/src/proxmox-backup
        make deb-nodoc
        install -m 0644 "proxmox-backup-file-restore_${version}_amd64.deb" $OUTPUT_DIR/
        # Free the large Rust build tree before other components build.
        make clean-deb
    )

    # The daemon must contain the ntfs-3g fallback.
    local check_dir
    check_dir=$(mktemp -d)
    dpkg-deb -x "$OUTPUT_DIR/proxmox-backup-file-restore_${version}_amd64.deb" "$check_dir"
    strings "$check_dir/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon" \
        | grep -qF 'try FUSE mount using ntfs-3g'
    rm -rf "$check_dir"
}

build_restore_image() {
    local version commit
    version=$(lock_field restore-image version)
    commit=$(lock_field restore-image commit)
    verify_patch_hash restore-image patches/proxmox-backup-restore-image-ntfs3g.patch

    clone_pinned "$RESTORE_IMAGE_REPOSITORY" "$commit" $WORK_DIR/src/proxmox-backup-restore-image
    clone_pinned "$DEDUP_PLUGIN_REPOSITORY" \
        "$(lock_field dedup-plugin commit)" $WORK_DIR/src/ntfs-3g-dedup-plugin
    mkdir -p $WORK_DIR/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin
    git -C $WORK_DIR/src/ntfs-3g-dedup-plugin archive --format=tar HEAD \
        | tar -x -C $WORK_DIR/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin
    patch -d $WORK_DIR/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin -p1 \
        < $PROJECT_DIR/patches/ntfs-3g-dedup-plugin-fuse3.patch
    patch -d $WORK_DIR/src/proxmox-backup-restore-image -p1 \
        < $PROJECT_DIR/patches/proxmox-backup-restore-image-ntfs3g.patch
    build_dependencies $WORK_DIR/src/proxmox-backup-restore-image
    (
        cd $WORK_DIR/src/proxmox-backup-restore-image
        make deb
        install -m 0644 "proxmox-backup-restore-image_${version}_amd64.deb" $OUTPUT_DIR/
    )

    # The initramfs must include ntfs-3g and the dedup plugin.
    local check_dir initramfs
    check_dir=$(mktemp -d)
    dpkg-deb -x "$OUTPUT_DIR/proxmox-backup-restore-image_${version}_amd64.deb" "$check_dir"
    initramfs="$check_dir/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
    lsinitramfs "$initramfs" | grep -qx 'usr/bin/ntfs-3g'
    lsinitramfs "$initramfs" | grep -qx 'usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so'
    rm -rf "$check_dir"
}

build_dedup_plugin() {
    local version commit
    version=$(lock_field dedup-plugin version)
    commit=$(lock_field dedup-plugin commit)
    verify_patch_hash dedup-plugin patches/ntfs-3g-dedup-plugin-fuse3.patch

    clone_pinned "$DEDUP_PLUGIN_REPOSITORY" "$commit" $WORK_DIR/src/ntfs-3g-dedup-plugin
    patch -d $WORK_DIR/src/ntfs-3g-dedup-plugin -p1 \
        < $PROJECT_DIR/patches/ntfs-3g-dedup-plugin-fuse3.patch
    (
        cd $WORK_DIR/src/ntfs-3g-dedup-plugin
        # The plugin's configure looks for fuse 2; point it at fuse3, the
        # same trick the restore-image build uses.
        mkdir -p pkgconfig
        ln -sf "$(pkg-config --variable=pcfiledir fuse3)/fuse3.pc" pkgconfig/fuse.pc
        export PKG_CONFIG_PATH="$PWD/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        autoreconf -fi
        ./configure
        make
    )

    local staging=$WORK_DIR/pkg/ntfs-3g-plugin-dedup
    rm -rf "$staging"
    mkdir -p "$staging/DEBIAN" \
        "$staging/usr/lib/x86_64-linux-gnu/ntfs-3g" \
        "$staging/usr/share/doc/ntfs-3g-plugin-dedup"
    install -m 0755 \
        $WORK_DIR/src/ntfs-3g-dedup-plugin/.libs/ntfs-plugin-80000013.so \
        "$staging/usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so"
    install -m 0644 $PROJECT_DIR/packaging/ntfs-3g-plugin-dedup/copyright \
        "$staging/usr/share/doc/ntfs-3g-plugin-dedup/copyright"
    sed -e "s/@VERSION@/$version/" \
        $PROJECT_DIR/packaging/ntfs-3g-plugin-dedup/control > "$staging/DEBIAN/control"
    dpkg-deb --root-owner-group --build "$staging" \
        "$OUTPUT_DIR/ntfs-3g-plugin-dedup_${version}_amd64.deb"
}

build_meta() {
    local version
    version=$(lock_field meta version)

    local staging=$WORK_DIR/pkg/pve-file-restore-ntfs3g
    rm -rf "$staging"
    mkdir -p "$staging/DEBIAN" \
        "$staging/usr/sbin" \
        "$staging/usr/share/doc/pve-file-restore-ntfs3g"
    install -m 0755 $PROJECT_DIR/packaging/pve-file-restore-ntfs3g/pve-file-restore-ntfs3g-check \
        "$staging/usr/sbin/pve-file-restore-ntfs3g-check"
    install -m 0644 $PROJECT_DIR/packaging/pve-file-restore-ntfs3g/copyright \
        "$staging/usr/share/doc/pve-file-restore-ntfs3g/copyright"
    sed -e "s/@VERSION@/$version/" \
        $PROJECT_DIR/packaging/pve-file-restore-ntfs3g/control > "$staging/DEBIAN/control"
    dpkg-deb --root-owner-group --build "$staging" \
        "$OUTPUT_DIR/pve-file-restore-ntfs3g_${version}_amd64.deb"
}

case $COMPONENT in
    file-restore) build_file_restore ;;
    restore-image) build_restore_image ;;
    dedup-plugin) build_dedup_plugin ;;
    meta) build_meta ;;
    all)
        build_file_restore
        build_restore_image
        build_dedup_plugin
        build_meta
        ;;
esac

(
    cd $OUTPUT_DIR
    rm -f SHA256SUMS
    sha256sum ./*.deb > SHA256SUMS
)

echo "Build complete. Assets written to $OUTPUT_DIR"
