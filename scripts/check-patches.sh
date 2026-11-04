#!/usr/bin/env bash
# Check locked patches, or select a patch set for an upstream tip/commit.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=./scripts/lib-lock.sh
source scripts/lib-lock.sh
# shellcheck source=./scripts/lib-patch.sh
source scripts/lib-patch.sh

usage() {
    echo "usage: $0 [--tip|--commit <commit>]" >&2
    exit 2
}

mode=locked
revision=locked
while [ "$#" -gt 0 ]; do
    case $1 in
        --tip)
            [ "$mode" = locked ] || usage
            mode=tip
            revision=tip
            shift
            ;;
        --commit)
            [ "$mode" = locked ] || usage
            [ "$#" -eq 2 ] || usage
            mode=commit
            revision=$2
            shift 2
            ;;
        *) usage ;;
    esac
done

check_locked() {
    local component=$1 paths
    paths=$(lock_field "$component" patches)
    if [ "$paths" = '-' ]; then
        echo "$component: no patches"
    else
        patch_check_locked "$component" >/dev/null
        echo "$component: locked patches apply ($paths)"
    fi
}

check_selected() {
    local component=$1 selected
    selected=$(patch_select_paths "$component" "$revision") || return 1
    echo "$component: selected $selected at $revision"
}

if [ "$mode" = locked ]; then
    while IFS= read -r component; do
        check_locked "$component"
    done < <(lock_components)
else
    successes=()
    for component in file-restore restore-image dedup-plugin; do
        if output=$(check_selected "$component" 2>/dev/null); then
            successes+=("$output")
        fi
    done
    [ "${#successes[@]}" -gt 0 ] || {
        echo "no component patch applies at $revision" >&2
        exit 1
    }
    if [ "$mode" = commit ] && [ "${#successes[@]}" -ne 1 ]; then
        echo "commit $revision matches multiple components; use a unique upstream commit" >&2
        printf '%s\n' "${successes[@]}" >&2
        exit 1
    fi
    printf '%s\n' "${successes[@]}"
fi

echo 'patch checks passed'
