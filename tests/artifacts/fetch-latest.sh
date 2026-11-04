#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <component> <artifacts-dir>" >&2; exit 2; }
component=$1
artifacts=$2
repo=${GH_REPO:-junglivre/pve-file-restore-ntfs3g}
case $component in
    file-restore|restore-image|dedup-plugin|meta) ;;
    *) echo "unknown component: $component" >&2; exit 2 ;;
esac

destination="$artifacts/$component"
mkdir -p "$destination"
existing=()
mapfile -t existing < <(find "$destination" -maxdepth 1 -type f -name '*.deb' -print)
if [ "${#existing[@]}" -ne 0 ]; then
    echo "using package already present for $component"
    exit 0
fi

# gh lists releases newest first, so the first matching tag is the newest one
# regardless of whether it is a stable or prerelease release.
tags=$(gh release list --repo "$repo" --limit 100 --exclude-drafts --json tagName --jq '.[].tagName')
tag=''
while IFS= read -r candidate; do
    case $candidate in
        "$component"/*) tag=$candidate; break ;;
    esac
done <<<"$tags"
[ -n "$tag" ] || { echo "no release found for $component" >&2; exit 1; }
echo "downloading latest release $tag"
gh release download "$tag" --repo "$repo" --dir "$destination" \
    --pattern '*.deb' --pattern SHA256SUMS
