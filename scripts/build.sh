#!/usr/bin/env bash
# Build the custom packages in a disposable, digest-pinned Debian 13 container.
#
#   scripts/build.sh --component <file-restore|restore-image|dedup-plugin|meta|all>
#
# Everything it builds is described by upstream.lock; the same script runs in
# CI (see .github/workflows/build.yml).
set -Eeuo pipefail

# debian:13, pinned by digest for reproducible builds.
BUILD_IMAGE='debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308'

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
OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT_DIR/dist"}
WORK_DIR=${WORK_DIR:-"$ROOT_DIR/.build"}

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

docker run --rm --init \
    --mount "type=bind,src=$ROOT_DIR,dst=/project,readonly" \
    --mount "type=bind,src=$WORK_DIR,dst=/work" \
    --mount "type=bind,src=$OUTPUT_DIR,dst=/out" \
    --env DEBIAN_FRONTEND=noninteractive \
    --env "BUILD_COMPONENT=$COMPONENT" \
    "$BUILD_IMAGE" \
    bash /project/scripts/build-in-container.sh
