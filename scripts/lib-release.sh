#!/usr/bin/env bash
# Shared local and published-release validation.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=./scripts/lib-lock.sh
source "$ROOT_DIR/scripts/lib-lock.sh"

release_repo() {
    local repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
    [ -n "$repo" ] || { echo 'GH_REPO or GITHUB_REPOSITORY is required' >&2; return 1; }
    printf '%s\n' "$repo"
}

release_tag_parts() {
    local tag=$1 component version
    component=${tag%%/*}
    version=${tag#*/}
    [ "$component/$version" = "$tag" ] || {
        echo "invalid release tag '$tag'" >&2
        return 1
    }
    if [ -z "$version" ] || [[ "$version" == */* ]]; then
        echo "invalid release tag '$tag'" >&2
        return 1
    fi
    lock_package "$component" >/dev/null
    printf '%s\n%s\n' "$component" "$version"
}

release_expected_asset() {
    local component=$1 version=$2
    printf '%s_%s_%s.deb\n' "$(lock_package "$component")" "$version" "$(lock_architecture "$component")"
}

release_validate_tag() {
    local tag=$1 component version
    mapfile -t parts < <(release_tag_parts "$tag")
    component=${parts[0]}
    version=${parts[1]}
    expected=$(release_expected_asset "$component" "$version")
    [[ "$tag" = "$component/$version" ]] || return 1
    [[ "$expected" != *'~'* ]] || {
        echo "release asset name contains GitHub-rewritten '~': $expected" >&2
        return 1
    }
    printf '%s\n%s\n%s\n' "$component" "$version" "$expected"
}

release_validate_asset_names() {
    local expected_deb=$1
    shift
    local names=("$@") name has_deb=0 has_sums=0
    [ "${#names[@]}" -eq 2 ] || {
        echo "release must contain exactly the .deb and SHA256SUMS (got ${#names[@]} assets)" >&2
        return 1
    }
    for name in "${names[@]}"; do
        [[ "$name" != *'~'* ]] || {
            echo "asset name was rewritten by GitHub: $name" >&2
            return 1
        }
        case $name in
            "$expected_deb") has_deb=1 ;;
            SHA256SUMS) has_sums=1 ;;
            *) echo "unexpected release asset: $name" >&2; return 1 ;;
        esac
    done
    if [ "$has_deb" -ne 1 ] || [ "$has_sums" -ne 1 ]; then
        echo "release assets do not contain the expected package and SHA256SUMS" >&2
        return 1
    fi
}

release_validate_directory() {
    local component=$1 version=$2 directory=$3 expected_deb
    expected_deb=$(release_expected_asset "$component" "$version")
    [ -d "$directory" ] || { echo "asset directory not found: $directory" >&2; return 1; }

    local files=()
    mapfile -t files < <(find "$directory" -maxdepth 1 -type f -printf '%f\n' | sort)
    release_validate_asset_names "$expected_deb" "${files[@]}" || return 1
    [ -f "$directory/$expected_deb" ] || {
        echo "missing expected package: $directory/$expected_deb" >&2
        return 1
    }
    [ "$(dpkg-deb -f "$directory/$expected_deb" Package)" = "$(lock_package "$component")" ] || {
        echo "Package field does not match $expected_deb" >&2
        return 1
    }
    [ "$(dpkg-deb -f "$directory/$expected_deb" Version)" = "$version" ] || {
        echo "Version field does not match tag/version $version" >&2
        return 1
    }
    [ "$(dpkg-deb -f "$directory/$expected_deb" Architecture)" = "$(lock_architecture "$component")" ] || {
        echo "Architecture field does not match component $component" >&2
        return 1
    }

    local checksum_names=()
    mapfile -t checksum_names < <(awk 'NF { print $2 }' "$directory/SHA256SUMS")
    if [ "${#checksum_names[@]}" -ne 1 ] || [ "${checksum_names[0]}" != "$expected_deb" ]; then
        echo 'SHA256SUMS must cover exactly the expected .deb' >&2
        return 1
    fi
    (cd "$directory" && sha256sum -c SHA256SUMS)
}

release_api_asset_names() {
    local tag=$1 repo
    repo=$(release_repo)
    gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name'
}

release_validate_remote() {
    local tag=$1 directory=$2 component version expected_deb
    mapfile -t parts < <(release_validate_tag "$tag")
    component=${parts[0]}
    version=${parts[1]}
    expected_deb=${parts[2]}
    mapfile -t assets < <(release_api_asset_names "$tag")
    release_validate_asset_names "$expected_deb" "${assets[@]}" || return 1
    mkdir -p "$directory"
    gh release download "$tag" --repo "$(release_repo)" --dir "$directory"
    release_validate_directory "$component" "$version" "$directory"
}

release_changelog_notes() {
    local tag=$1 commit=$2 base=${3:-${RELEASE_BASE:-}} heading="## $1"
    awk -v heading="$heading" '
        $0 == heading { capture = 1; next }
        capture && /^##+ / { exit }
        capture { print }
    ' "$ROOT_DIR/CHANGELOG.md"
    if ! awk -v heading="$heading" '$0 == heading { found = 1 } END { exit !found }' \
        "$ROOT_DIR/CHANGELOG.md"; then
        local component=${tag%%/*} version=${tag#*/} previous ref
        for ref in "$base" HEAD^; do
            [ -n "$ref" ] || continue
            if previous=$(git -C "$ROOT_DIR" show "$ref:upstream.lock" 2>/dev/null |
                awk -v component="$component" '$1 == component { print $2; exit }'); then
                if [ -n "$previous" ]; then
                    printf 'upstream bump %s -> %s (commit %s).\n' "$previous" "$version" "$commit"
                    return 0
                fi
            fi
        done
        printf 'new release %s (commit %s).\n' "$version" "$commit"
    fi
}
