#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <artifacts-dir> <fixture-dir>" >&2; exit 2; }
artifacts=$1
fixture=$2
mapfile -t plugins < <(find "$artifacts/dedup-plugin" -maxdepth 1 -type f -name 'ntfs-3g-plugin-dedup_*.deb' -print)
[ "${#plugins[@]}" -eq 1 ] || { echo 'expected one dedup plugin package' >&2; exit 1; }

"$(dirname -- "${BASH_SOURCE[0]}")/run.sh" none "$fixture"
"$(dirname -- "${BASH_SOURCE[0]}")/run.sh" "${plugins[0]}" "$fixture"
