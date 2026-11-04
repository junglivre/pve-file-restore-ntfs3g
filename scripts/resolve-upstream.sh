#!/usr/bin/env bash
# Resolve the upstream release commit for a component + upstream version.
#
# proxmox-backup only has tags up to v4.2.0 and proxmox-backup-restore-image
# has no tags at all, so the trusted reference is the release commit message:
#
#   scripts/resolve-upstream.sh file-restore 4.2.8-1
#   scripts/resolve-upstream.sh restore-image 1.0.0
#
# Prints the full commit hash of "bump version to <upstream version>".
# Exits non-zero when there is not exactly one such commit.
set -Eeuo pipefail

die() { echo "resolve-upstream: $*" >&2; exit 1; }

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=./scripts/lib-lock.sh
source "$ROOT_DIR/scripts/lib-lock.sh"

[ $# -eq 2 ] || die "usage: $0 <file-restore|restore-image> <upstream version>"

component=$1
upstream_version=$2

case $component in
    file-restore|restore-image) url=$(lock_source_url "$component") ;;
    *) die "unknown component '$component'" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# git.proxmox.com ignores --filter, so fetch the full (bare) history.
git clone --bare --quiet "$url" "$tmp/repo"

matches=$(git -C "$tmp/repo" log --all --format='%H' \
    --grep "^bump version to ${upstream_version}\$")

count=$(grep -c . <<<"$matches" || true)
[ "$count" -eq 1 ] || die "expected exactly 1 commit 'bump version to $upstream_version' in $url, found $count"

printf '%s\n' "$matches"
