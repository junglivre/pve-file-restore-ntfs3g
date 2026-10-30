#!/usr/bin/env bash
# Validate and publish immutable component pre-releases.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=./scripts/lib-release.sh
source "$ROOT_DIR/scripts/lib-release.sh"

[ "$#" -ge 1 ] || { echo "usage: $0 <artifacts-dir> [component ...]" >&2; exit 2; }
artifacts=$1
shift
if [ "$#" -eq 0 ]; then
    mapfile -t components < <(lock_components)
else
    components=("$@")
fi

lock_verify
repo=$(release_repo)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for component in "${components[@]}"; do
    version=$(lock_field "$component" version)
    commit=$(lock_field "$component" commit)
    tag="$component/$version"
    expected_deb=$(release_expected_asset "$component" "$version")

    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        echo ":: $tag already exists; immutable release left unchanged"
        continue
    fi

    source_dir="$artifacts/$component"
    [ -d "$source_dir" ] || { echo "missing build artifact directory: $source_dir" >&2; exit 1; }
    mapfile -t input_debs < <(find "$source_dir" -maxdepth 1 -type f -name '*.deb' -printf '%f\n')
    if [ "${#input_debs[@]}" -ne 1 ] || [ "${input_debs[0]}" != "$expected_deb" ]; then
        echo "$component must provide exactly $expected_deb" >&2
        exit 1
    fi

    output_dir="$work/$component"
    mkdir -p "$output_dir"
    cp -- "$source_dir/$expected_deb" "$output_dir/$expected_deb"
    (cd "$output_dir" && sha256sum -- "$expected_deb" > SHA256SUMS)
    release_validate_directory "$component" "$version" "$output_dir"

    notes="$work/$component.notes"
    {
        release_changelog_notes "$tag" "$commit"
        echo
        echo "Upstream commit: \`$commit\`."
        echo 'Verify the attached package with sha256sum -c SHA256SUMS.'
    } > "$notes"
    gh release create "$tag" --repo "$repo" --prerelease --latest=false \
        --target "${GITHUB_SHA:-HEAD}" --title "$tag" --notes-file "$notes" \
        "$output_dir/$expected_deb" "$output_dir/SHA256SUMS"
    echo "published $tag"
done
