#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -ge 2 ] || { echo "usage: $0 <artifacts-dir> <fixture-dir>..." >&2; exit 2; }
artifacts=$1
shift
mapfile -t plugins < <(find "$artifacts/dedup-plugin" -maxdepth 1 -type f -name 'ntfs-3g-plugin-dedup_*.deb' -print)
[ "${#plugins[@]}" -eq 1 ] || { echo 'expected one dedup plugin package' >&2; exit 1; }

# Without the plugin every fixture must fail exactly on its Dedup paths, so
# run all of them before installing it.
for fixture in "$@"; do
    "$(dirname -- "${BASH_SOURCE[0]}")/run.sh" none "$fixture"
done
for fixture in "$@"; do
    "$(dirname -- "${BASH_SOURCE[0]}")/run.sh" "${plugins[0]}" "$fixture"
done
