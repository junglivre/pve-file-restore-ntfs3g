#!/usr/bin/env bash
# Build the custom packages in a disposable, digest-pinned Debian 13 container.
#
#   scripts/build.sh --component <file-restore|restore-image|dedup-plugin|meta|all>
#
# Everything it builds is described by upstream.lock; the same script runs in
# CI (see .github/workflows/build.yml).
set -Eeuo pipefail

# shellcheck source=./scripts/lib-lock.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib-lock.sh"

# The image digest is kept in lib-lock.sh so the lock hash and the build use
# exactly the same container identity.
BUILD_IMAGE=$LOCK_BUILD_IMAGE

usage() {
    echo "usage: $0 --component <file-restore|restore-image|dedup-plugin|meta|all>" >&2
    exit 2
}

COMPONENT=''
while [ $# -gt 0 ]; do
    case $1 in
        --component) COMPONENT=$2; shift 2 ;;
        *) usage ;;
    esac
done
case $COMPONENT in
    file-restore|restore-image|dedup-plugin|meta|all) ;;
    *) usage ;;
esac

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT_ROOT_DIR=${OUTPUT_ROOT_DIR:-${OUTPUT_DIR:-"$ROOT_DIR/dist"}}
WORK_DIR=${WORK_DIR:-"$ROOT_DIR/.build"}

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required." >&2
    exit 1
fi

mkdir -p "$OUTPUT_ROOT_DIR" "$WORK_DIR"
# A component build must never select a stale package or checksum from a
# previous component build. A restore-image build may keep the exact plugin
# package supplied by its dependency job.
component_output_dir() {
    printf '%s/%s\n' "$OUTPUT_ROOT_DIR" "$1"
}

clean_component_output() {
    local component=$1 output_dir
    output_dir=$(component_output_dir "$component")
    mkdir -p "$output_dir"
    find "$output_dir" -maxdepth 1 -type f \
        \( -name '*.deb' -o -name SHA256SUMS \) -delete
}

if [ "$COMPONENT" = all ]; then
    for component in file-restore restore-image dedup-plugin meta; do
        clean_component_output "$component"
    done
else
    clean_component_output "$COMPONENT"
fi

prepare_plugin_package() {
    local version package tmp
    version=$(lock_field dedup-plugin version)
    package="ntfs-3g-plugin-dedup_${version}_amd64.deb"
    local plugin_dir
    plugin_dir=$(component_output_dir dedup-plugin)
    mkdir -p "$plugin_dir"
    [ -f "$plugin_dir/$package" ] && return 0
    command -v gh >/dev/null 2>&1 || {
        echo "dedup-plugin release $version is unavailable and gh is required to fetch it" >&2
        exit 1
    }
    tmp=$(mktemp -d)
    gh release download "dedup-plugin/$version" \
        --repo "${GH_REPO:?GH_REPO is required to fetch dedup-plugin}" \
        --pattern "$package" --pattern SHA256SUMS --dir "$tmp"
    (cd "$tmp" && grep -qx "[0-9a-f][0-9a-f]*  $package" SHA256SUMS && sha256sum -c SHA256SUMS)
    install -m 0644 "$tmp/$package" "$plugin_dir/$package"
    rm -rf "$tmp"
}

if [ "$COMPONENT" = restore-image ]; then
    prepare_plugin_package
fi

docker run --rm --init \
    --mount "type=bind,src=$ROOT_DIR,dst=/project,readonly" \
    --mount "type=bind,src=$WORK_DIR,dst=/work" \
    --mount "type=bind,src=$OUTPUT_ROOT_DIR,dst=/out" \
    --env DEBIAN_FRONTEND=noninteractive \
    --env "BUILD_COMPONENT=$COMPONENT" \
    --env OUTPUT_ROOT_DIR=/out \
    "$BUILD_IMAGE" \
    bash /project/scripts/build-in-container.sh
