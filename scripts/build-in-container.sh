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

# shellcheck source=./scripts/lib-lock.sh
source "$PROJECT_DIR/scripts/lib-lock.sh"
cd "$PROJECT_DIR"

COMPONENT=${BUILD_COMPONENT:?BUILD_COMPONENT is required}

if [ "$COMPONENT" = all ]; then
    lock_verify
else
    lock_verify_component "$COMPONENT"
fi

mkdir -p "$WORK_DIR/src" "$WORK_DIR/pkg" "$OUTPUT_DIR"

export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS=nocheck

readonly PROXMOX_KEYRING_URL='https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg'
# The runner has no trusted Proxmox keyring; pin the downloaded key bytes
# before apt is allowed to use them. The owner-maintained fingerprint source
# is unavailable in the offline build sandbox, so this uses its published
# SHA-256 digest as the equivalent immutable key identity.
readonly PROXMOX_KEYRING_SHA256='136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45'

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg build-essential devscripts equivs lintian \
    autoconf automake libtool pkg-config ntfs-3g-dev libfuse3-dev python3-sphinx \
    initramfs-tools-core

curl -fsSL "$PROXMOX_KEYRING_URL" -o /usr/share/keyrings/proxmox-archive-keyring-trixie.gpg
key_hash=$(sha256sum /usr/share/keyrings/proxmox-archive-keyring-trixie.gpg)
key_hash=${key_hash%% *}
[ "$key_hash" = "$PROXMOX_KEYRING_SHA256" ] || {
    echo 'Proxmox archive key digest mismatch' >&2
    exit 1
}
cat >/etc/apt/sources.list.d/proxmox-devel.list <<'EOF'
deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring-trixie.gpg] http://download.proxmox.com/debian/devel trixie main
EOF
apt-get update

# Record the exact state of the Proxmox devel repository in the build log, so
# a build can be traced back to the repository snapshot it used.
echo "== proxmox devel repository snapshot =="
curl -fsSL http://download.proxmox.com/debian/devel/dists/trixie/InRelease \
    -o "$WORK_DIR/proxmox-devel-InRelease"
grep -E '^(Date|Valid-Until):' "$WORK_DIR/proxmox-devel-InRelease" || true
sha256sum "$WORK_DIR/proxmox-devel-InRelease"

clone_pinned() {
    local component=$1 destination=$2 commit url ref fetched
    commit=$(lock_field "$component" commit)
    url=$(lock_source_url "$component")
    ref=$(lock_source_ref "$component")
    rm -rf "$destination"
    git clone --quiet "$url" "$destination"
    git -C "$destination" fetch --quiet origin "$ref"
    fetched=$(git -C "$destination" rev-parse FETCH_HEAD)
    git -C "$destination" merge-base --is-ancestor "$commit" "$fetched" || {
        echo "Pinned revision $commit is not reachable from $url#$ref" >&2
        exit 1
    }
    git -C "$destination" checkout --quiet "$commit"
}

build_dependencies() {
    local source_dir=$1
    (
        cd "$source_dir"
        mk-build-deps -i --tool 'apt-get --no-install-recommends -y' debian/control
    )
}

add_changelog_entry() {
    local source_dir=$1 version=$2
    (
        cd "$source_dir"
        export DEBFULLNAME="$LOCK_DCH_NAME"
        export DEBEMAIL="$LOCK_DCH_EMAIL"
        dch --newversion "$version" --distribution trixie --force-distribution \
            "Rebuild with the pve-file-restore-ntfs3g patch set."
    )
}

build_file_restore() {
    local version
    version=$(lock_field file-restore version)

    clone_pinned file-restore "$WORK_DIR/src/proxmox-backup"
    while IFS= read -r patch_file; do
        patch -d "$WORK_DIR/src/proxmox-backup" -p1 < "$PROJECT_DIR/$patch_file"
    done < <(lock_patch_paths file-restore)
    add_changelog_entry "$WORK_DIR/src/proxmox-backup" "$version"

    build_dependencies "$WORK_DIR/src/proxmox-backup"
    (
        cd "$WORK_DIR/src/proxmox-backup"
        make deb-nodoc
        install -m 0644 "proxmox-backup-file-restore_${version}_amd64.deb" "$OUTPUT_DIR/"
        # Free the large Rust build tree before other components build.
        make clean-deb
    )

    # The daemon must contain the ntfs-3g fallback.
    local check_dir
    check_dir=$(mktemp -d)
    dpkg-deb -x "$OUTPUT_DIR/proxmox-backup-file-restore_${version}_amd64.deb" "$check_dir"
    grep -qF 'try FUSE mount using ntfs-3g' \
        < <(strings "$check_dir/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon")
    rm -rf "$check_dir"
}

build_restore_image() {
    local version patch_file
    version=$(lock_field restore-image version)

    clone_pinned restore-image "$WORK_DIR/src/proxmox-backup-restore-image"
    clone_pinned dedup-plugin "$WORK_DIR/src/ntfs-3g-dedup-plugin"
    mkdir -p "$WORK_DIR/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin"
    git -C "$WORK_DIR/src/ntfs-3g-dedup-plugin" archive --format=tar HEAD \
        | tar -x -C "$WORK_DIR/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin"
    while IFS= read -r patch_file; do
        case $patch_file in
            *ntfs-3g-dedup-plugin*)
                patch -d "$WORK_DIR/src/proxmox-backup-restore-image/src/ntfs-3g-dedup-plugin" \
                    -p1 < "$PROJECT_DIR/$patch_file"
                ;;
            *) patch -d "$WORK_DIR/src/proxmox-backup-restore-image" -p1 \
                < "$PROJECT_DIR/$patch_file" ;;
        esac
    done < <(lock_patch_paths restore-image)
    add_changelog_entry "$WORK_DIR/src/proxmox-backup-restore-image" "$version"

    build_dependencies "$WORK_DIR/src/proxmox-backup-restore-image"
    (
        cd "$WORK_DIR/src/proxmox-backup-restore-image"
        make deb
        install -m 0644 "proxmox-backup-restore-image_${version}_amd64.deb" "$OUTPUT_DIR/"
    )

    # The initramfs must include ntfs-3g and the dedup plugin.
    local check_dir initramfs
    check_dir=$(mktemp -d)
    dpkg-deb -x "$OUTPUT_DIR/proxmox-backup-restore-image_${version}_amd64.deb" "$check_dir"
    initramfs="$check_dir/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
    grep -qx 'usr/bin/ntfs-3g' < <(lsinitramfs "$initramfs")
    grep -qx 'usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so' < <(lsinitramfs "$initramfs")
    rm -rf "$check_dir"
}

build_dedup_plugin() {
    local version patch_file
    version=$(lock_field dedup-plugin version)

    clone_pinned dedup-plugin "$WORK_DIR/src/ntfs-3g-dedup-plugin"
    while IFS= read -r patch_file; do
        patch -d "$WORK_DIR/src/ntfs-3g-dedup-plugin" -p1 \
            < "$PROJECT_DIR/$patch_file"
    done < <(lock_patch_paths dedup-plugin)
    (
        cd "$WORK_DIR/src/ntfs-3g-dedup-plugin"
        # The plugin's configure looks for fuse 2; point it at fuse3, the
        # same trick the restore-image build uses.
        mkdir -p pkgconfig
        ln -sf "$(pkg-config --variable=pcfiledir fuse3)/fuse3.pc" pkgconfig/fuse.pc
        export PKG_CONFIG_PATH="$PWD/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        autoreconf -fi
        ./configure
        make
    )

    local staging="$WORK_DIR/pkg/ntfs-3g-plugin-dedup"
    rm -rf "$staging"
    mkdir -p "$staging/DEBIAN" \
        "$staging/usr/lib/x86_64-linux-gnu/ntfs-3g" \
        "$staging/usr/share/doc/ntfs-3g-plugin-dedup"
    install -m 0755 \
        "$WORK_DIR/src/ntfs-3g-dedup-plugin/.libs/ntfs-plugin-80000013.so" \
        "$staging/usr/lib/x86_64-linux-gnu/ntfs-3g/ntfs-plugin-80000013.so"
    install -m 0644 "$PROJECT_DIR/packaging/ntfs-3g-plugin-dedup/copyright" \
        "$staging/usr/share/doc/ntfs-3g-plugin-dedup/copyright"
    sed -e "s/@VERSION@/$version/" \
        "$PROJECT_DIR/packaging/ntfs-3g-plugin-dedup/control" > "$staging/DEBIAN/control"
    local source_date_epoch
    source_date_epoch=$(lock_last_change_epoch dedup-plugin)
    export SOURCE_DATE_EPOCH="$source_date_epoch"
    dpkg-deb --root-owner-group --build "$staging" \
        "$OUTPUT_DIR/ntfs-3g-plugin-dedup_${version}_amd64.deb"
}

build_meta() {
    local version
    version=$(lock_field meta version)

    local staging="$WORK_DIR/pkg/pve-file-restore-ntfs3g"
    rm -rf "$staging"
    mkdir -p "$staging/DEBIAN" \
        "$staging/usr/sbin" \
        "$staging/usr/share/doc/pve-file-restore-ntfs3g"
    install -m 0755 "$PROJECT_DIR/packaging/pve-file-restore-ntfs3g/pve-file-restore-ntfs3g-check" \
        "$staging/usr/sbin/pve-file-restore-ntfs3g-check"
    install -m 0644 "$PROJECT_DIR/packaging/pve-file-restore-ntfs3g/copyright" \
        "$staging/usr/share/doc/pve-file-restore-ntfs3g/copyright"
    sed -e "s/@VERSION@/$version/" \
        "$PROJECT_DIR/packaging/pve-file-restore-ntfs3g/control" > "$staging/DEBIAN/control"
    local source_date_epoch
    source_date_epoch=$(lock_last_change_epoch meta)
    export SOURCE_DATE_EPOCH="$source_date_epoch"
    dpkg-deb --root-owner-group --build "$staging" \
        "$OUTPUT_DIR/pve-file-restore-ntfs3g_${version}_all.deb"
}

case $COMPONENT in
    file-restore) build_file_restore ;;
    restore-image) build_restore_image ;;
    dedup-plugin) build_dedup_plugin ;;
    meta) build_meta ;;
    all)
        build_file_restore
        build_dedup_plugin
        build_restore_image
        build_meta
        ;;
esac

(
    cd "$OUTPUT_DIR"
    rm -f SHA256SUMS
    if [ "$COMPONENT" = all ]; then
        sha256sum ./*.deb > SHA256SUMS
    else
        sha256sum "$(lock_package "$COMPONENT")_$(lock_field "$COMPONENT" version)_$(lock_architecture "$COMPONENT").deb" > SHA256SUMS
    fi
)

echo "Build complete. Assets written to $OUTPUT_DIR"
