#!/usr/bin/env bash
# Build the two custom PVE File Restore packages in a disposable container.
set -Eeuo pipefail

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
    debian:13 \
    bash /project/scripts/build-in-container.sh
