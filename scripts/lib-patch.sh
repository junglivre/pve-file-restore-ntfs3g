#!/usr/bin/env bash
# Shared upstream checkout and patch-selection helpers.
set -Eeuo pipefail

PATCH_ROOT_DIR=${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}

if ! declare -F lock_field >/dev/null 2>&1; then
    # shellcheck source=./scripts/lib-lock.sh
    source "$PATCH_ROOT_DIR/scripts/lib-lock.sh"
fi

patch_error() {
    echo "patch: $*" >&2
    return 1
}

patch_revision() {
    local component=$1 requested=${2:-locked}
    case $requested in
        locked) lock_field "$component" commit ;;
        tip) printf '%s\n' tip ;;
        *) printf '%s\n' "$requested" ;;
    esac
}

patch_clone() {
    local component=$1 destination=$2 requested=${3:-locked}
    local url ref pinned fetched target
    url=$(lock_source_url "$component") || return 1
    ref=$(lock_source_ref "$component") || return 1
    pinned=$(lock_field "$component" commit) || return 1
    target=$(patch_revision "$component" "$requested") || return 1

    [ ! -e "$destination" ] || { patch_error "destination already exists: $destination"; return 1; }
    git clone --quiet "$url" "$destination" || return 1
    git -C "$destination" fetch --quiet origin "$ref" || return 1
    fetched=$(git -C "$destination" rev-parse FETCH_HEAD) || return 1
    if [ "$target" = tip ]; then
        target=$fetched
    fi
    git -C "$destination" cat-file -e "$target^{commit}" || {
        patch_error "revision $target is not reachable from $url#$ref"
        return 1
    }
    git -C "$destination" merge-base --is-ancestor "$target" "$fetched" || {
        patch_error "revision $target is not reachable from fetched $url#$ref ($fetched)"
        return 1
    }
    if [ "$requested" = locked ]; then
        if [ "$target" != "$pinned" ]; then
            patch_error "locked revision changed for $component"
            return 1
        fi
    fi
    git -C "$destination" checkout --quiet --detach "$target" || return 1
    printf '%s\n' "$target" || return 1
}

patch_prepare_tree() {
    local component=$1 destination=$2 requested=${3:-locked}
    local plugin_tmp
    patch_clone "$component" "$destination" "$requested" >/dev/null || return 1
    if [ "$component" = restore-image ]; then
        plugin_tmp=$(mktemp -d) || return 1
        patch_clone dedup-plugin "$plugin_tmp/source" >/dev/null || {
            rm -rf "$plugin_tmp"
            return 1
        }
        mkdir -p "$destination/src/ntfs-3g-dedup-plugin" || {
            rm -rf "$plugin_tmp"
            return 1
        }
        git -C "$plugin_tmp/source" archive --format=tar HEAD \
            | tar -x -C "$destination/src/ntfs-3g-dedup-plugin" || {
                rm -rf "$plugin_tmp"
                return 1
            }
        rm -rf "$plugin_tmp" || return 1
    fi
}

patch_path_directory() {
    local component=$1 patch_file=$2
    if [ "$component" != restore-image ]; then
        printf '%s\n' ''
        return 0
    fi
    case $patch_file in
        *ntfs-3g-dedup-plugin*) printf '%s\n' src/ntfs-3g-dedup-plugin ;;
        *) printf '%s\n' '' ;;
    esac
}

patch_apply_paths() {
    local component=$1 destination=$2 paths=$3 patch_file directory
    IFS=',' read -ra patch_list <<<"$paths"
    for patch_file in "${patch_list[@]}"; do
        [ -n "$patch_file" ] || { patch_error 'empty patch path'; return 1; }
        [ -f "$PATCH_ROOT_DIR/$patch_file" ] || {
            patch_error "missing patch file: $patch_file"
            return 1
        }
        directory=$(patch_path_directory "$component" "$patch_file") || return 1
        if [ -n "$directory" ]; then
            git -C "$destination" apply --check --whitespace=error \
                --directory="$directory" "$PATCH_ROOT_DIR/$patch_file" || return 1
            git -C "$destination" apply --whitespace=error \
                --directory="$directory" "$PATCH_ROOT_DIR/$patch_file" || return 1
        else
            git -C "$destination" apply --check --whitespace=error \
                "$PATCH_ROOT_DIR/$patch_file" || return 1
            git -C "$destination" apply --whitespace=error \
                "$PATCH_ROOT_DIR/$patch_file" || return 1
        fi
    done
}

patch_select_paths_in_tree() {
    local component=$1 destination=$2 requested=${3:-tip} candidate selected revision
    local candidates=()
    mapfile -t candidates < <(patch_selection_candidates "$component") || return 1
    [ "${#candidates[@]}" -gt 0 ] || {
        patch_error "$component has no patches"
        return 1
    }
    revision=$(patch_revision "$component" "$requested") || return 1
    for candidate in "${candidates[@]}"; do
        if patch_apply_paths "$component" "$destination" "$candidate"; then
            selected=$candidate
            printf '%s\n' "$selected" || return 1
            return 0
        fi
        git -C "$destination" reset --hard --quiet "$revision" || return 1
        git -C "$destination" clean -fdq || return 1
    done
    patch_error "no patch selection applies for $component at $requested"
}

patch_apply_locked() {
    local component=$1 destination=$2 paths
    paths=$(lock_field "$component" patches) || return 1
    if [ "$paths" = '-' ]; then
        return 0
    fi
    patch_apply_paths "$component" "$destination" "$paths" || return 1
}

patch_next_paths() {
    local component=$1 paths=$2 patch_file next_path replacement found=0
    if [ -f "$PATCH_ROOT_DIR/patches/next/$component.patch" ]; then
        printf '%s\n' "patches/next/$component.patch"
        return 0
    fi

    IFS=',' read -ra patch_list <<<"$paths"
    replacement=''
    for patch_file in "${patch_list[@]}"; do
        next_path="patches/next/$(basename -- "$patch_file")"
        if [ -f "$PATCH_ROOT_DIR/$next_path" ]; then
            found=1
            replacement+="${replacement:+,}$next_path"
        else
            replacement+="${replacement:+,}$patch_file"
        fi
    done
    if [ "$found" -eq 1 ]; then
        printf '%s\n' "$replacement"
    fi
}

patch_selection_candidates() {
    local component=$1 current
    current=$(lock_field "$component" patches) || return 1
    [ "$current" != '-' ] || return 0
    printf '%s\n' "$current"
    patch_next_paths "$component" "$current" || true
}

patch_select_paths() {
    local component=$1 requested=${2:-tip} candidate work selected
    local candidates=()
    mapfile -t candidates < <(patch_selection_candidates "$component") || return 1
    [ "${#candidates[@]}" -gt 0 ] || {
        patch_error "$component has no patches"
        return 1
    }
    for candidate in "${candidates[@]}"; do
        work=$(mktemp -d) || return 1
        if patch_prepare_tree "$component" "$work/source" "$requested" &&
            patch_apply_paths "$component" "$work/source" "$candidate"; then
            selected=$candidate
            rm -rf "$work" || return 1
            printf '%s\n' "$selected" || return 1
            return 0
        fi
        rm -rf "$work" || return 1
    done
    patch_error "no patch selection applies for $component at $requested"
}

patch_check_locked() {
    local component=$1 work
    work=$(mktemp -d) || return 1
    patch_prepare_tree "$component" "$work/source" locked || {
        rm -rf "$work"
        return 1
    }
    patch_apply_locked "$component" "$work/source" || {
        rm -rf "$work"
        return 1
    }
    rm -rf "$work" || return 1
    printf '%s\n' "$(lock_field "$component" patches)" || return 1
}
