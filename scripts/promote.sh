#!/usr/bin/env bash
# Revalidate an immutable testing release, then promote it in production.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=./scripts/lib-release.sh
source "$ROOT_DIR/scripts/lib-release.sh"

[ "$#" -eq 1 ] || { echo "usage: $0 <component/version-tag>" >&2; exit 2; }
tag=$1
repo=$(release_repo)
prerelease=$(gh release view "$tag" --repo "$repo" --json isPrerelease --jq '.isPrerelease')
[ "$prerelease" = true ] || { echo "$tag is not a pre-release" >&2; exit 1; }

download_dir=$(mktemp -d)
trap 'rm -rf "$download_dir"' EXIT
release_validate_remote "$tag" "$download_dir"
gh release edit "$tag" --repo "$repo" --prerelease=false --latest=false
echo "$tag promoted to stable."
