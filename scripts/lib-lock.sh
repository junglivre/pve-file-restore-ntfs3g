#!/usr/bin/env bash
# Parser and verifier for upstream.lock. Source this file for lock_field and
# the component maps; execute it for verification and change filtering.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly LOCK_FILE="$ROOT_DIR/upstream.lock"
readonly LOCK_BUILD_IMAGE='debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308'
# shellcheck disable=SC2034 # consumed by the sourced container build script
readonly LOCK_DCH_NAME='junglivre'
# shellcheck disable=SC2034 # consumed by the sourced container build script
readonly LOCK_DCH_EMAIL='junglivre@users.noreply.github.com'

lock_components() {
    printf '%s\n' file-restore restore-image dedup-plugin meta
}

lock_package() {
    case $1 in
        file-restore) printf '%s\n' proxmox-backup-file-restore ;;
        restore-image) printf '%s\n' proxmox-backup-restore-image ;;
        dedup-plugin) printf '%s\n' ntfs-3g-plugin-dedup ;;
        meta) printf '%s\n' pve-file-restore-ntfs3g ;;
        *) echo "unknown component '$1'" >&2; return 1 ;;
    esac
}

lock_architecture() {
    case $1 in
        file-restore|restore-image|dedup-plugin) printf '%s\n' amd64 ;;
        meta) printf '%s\n' all ;;
        *) echo "unknown component '$1'" >&2; return 1 ;;
    esac
}

lock_line_from_file() {
    local component=$1 file=$2
    awk -v component="$component" '$1 == component { print; found = 1; exit } END { if (!found) exit 1 }' "$file"
}

lock_field_from_file() {
    local component=$1 field=$2 file=$3 line
    line=$(lock_line_from_file "$component" "$file") || {
        echo "component '$component' not found in $file" >&2
        return 1
    }
    local _component version commit patches inputs source
    read -r _component version commit patches inputs source <<<"$line"
    case $field in
        version) printf '%s\n' "$version" ;;
        commit) printf '%s\n' "$commit" ;;
        patches) printf '%s\n' "$patches" ;;
        inputs_sha256) printf '%s\n' "${inputs#sha256:}" ;;
        source) printf '%s\n' "$source" ;;
        *) echo "unknown lock field '$field'" >&2; return 1 ;;
    esac
}

lock_field() {
    lock_field_from_file "$1" "$2" "$LOCK_FILE"
}

lock_patch_paths() {
    local component=$1 patches
    patches=$(lock_field "$component" patches)
    [ "$patches" != '-' ] || return 0
    local patch
    IFS=',' read -ra patch_list <<<"$patches"
    for patch in "${patch_list[@]}"; do
        [ -n "$patch" ] || { echo "empty patch path for $component" >&2; return 1; }
        printf '%s\n' "$patch"
    done
}

lock_source_url() {
    local source
    source=$(lock_field "$1" source)
    [ "$source" != '-' ] || { echo "component '$1' has no source" >&2; return 1; }
    [[ "$source" == *'#'* ]] || { echo "invalid source '$source'" >&2; return 1; }
    printf '%s\n' "${source%#*}"
}

lock_source_ref() {
    local source
    source=$(lock_field "$1" source)
    [ "$source" != '-' ] || { echo "component '$1' has no source" >&2; return 1; }
    [[ "$source" == *'#'* ]] || { echo "invalid source '$source'" >&2; return 1; }
    printf '%s\n' "${source##*#}"
}

lock_input_paths() {
    local component=$1 path
    while IFS= read -r path; do
        printf '%s\n' "$path"
    done < <(lock_patch_paths "$component")

    case $component in
        dedup-plugin) find "$ROOT_DIR/packaging/ntfs-3g-plugin-dedup" -type f -printf '%P\n' |
            sed 's#^#packaging/ntfs-3g-plugin-dedup/#' | sort ;;
        meta) find "$ROOT_DIR/packaging/pve-file-restore-ntfs3g" -type f -printf '%P\n' |
            sed 's#^#packaging/pve-file-restore-ntfs3g/#' | sort ;;
    esac

    # These helpers affect package contents or metadata for every component.
    printf '%s\n' scripts/build-in-container.sh scripts/build.sh scripts/lib-lock.sh
    if [ -f "$ROOT_DIR/scripts/lib-patch.sh" ]; then
        printf '%s\n' scripts/lib-patch.sh
    fi
}

lock_input_hash() {
    local component=$1 path actual manifest
    manifest=$(mktemp)
    while IFS= read -r path; do
        [ -f "$ROOT_DIR/$path" ] || {
            echo "missing lock input for $component: $path" >&2
            rm -f "$manifest"
            return 1
        }
        actual=$(sha256sum "$ROOT_DIR/$path")
        actual=${actual%% *}
        printf '%s  %s\n' "$actual" "$path" >> "$manifest"
    done < <(lock_input_paths "$component")
    printf 'container-image %s\n' "$LOCK_BUILD_IMAGE" >> "$manifest"
    sha256sum "$manifest" | awk '{print $1}'
    rm -f "$manifest"
}

lock_last_change_epoch() {
    local component=$1
    git -C "$ROOT_DIR" log -1 --format='%ct' -G "^${component}[[:space:]]" -- upstream.lock
}

lock_replace_line() {
    local component=$1 version=$2 commit=$3 patches=$4 inputs=$5 source=$6
    python3 - "$component" "$version" "$commit" "$patches" "$inputs" "$source" "$LOCK_FILE" <<'PY'
import re
import sys

component, version, commit, patches, inputs, source, path = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    lines = stream.readlines()
replacement = f'{component:<14} {version:<29} {commit:<41} {patches:<90} sha256:{inputs} {source}\n'
found = False
with open(path, 'w', encoding='utf-8') as stream:
    for line in lines:
        if re.match(rf'^{re.escape(component)}\s', line):
            stream.write(replacement)
            found = True
        else:
            stream.write(line)
if not found:
    raise SystemExit(f"component {component!r} not found in {path}")
PY
}

lock_update() {
    local component=$1 version=$2 commit=$3 patches=$4 source=$5 inputs
    lock_replace_line "$component" "$version" "$commit" "$patches" '-' "$source"
    inputs=$(lock_input_hash "$component")
    lock_replace_line "$component" "$version" "$commit" "$patches" "$inputs" "$source"
}

lock_verify_component() {
    local component=$1 expected actual
    expected=$(lock_field "$component" inputs_sha256)
    actual=$(lock_input_hash "$component")
    [ "$expected" = "$actual" ] || {
        echo "inputs hash mismatch for $component" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        return 1
    }
}

lock_verify_against() {
    local ref=$1 base_file component current_version base_version field current base result=0
    base_file=$(mktemp)
    if ! git -C "$ROOT_DIR" show "$ref:upstream.lock" >"$base_file" 2>/dev/null; then
        echo "cannot read $ref:upstream.lock; fetch the base ref before running verification" >&2
        rm -f "$base_file"
        return 1
    fi
    while IFS= read -r component; do
        current_version=$(lock_field "$component" version)
        base_version=$(lock_field_from_file "$component" version "$base_file")
        if [ "$current_version" = "$base_version" ]; then
            for field in commit patches inputs_sha256 source; do
                current=$(lock_field "$component" "$field")
                base=$(lock_field_from_file "$component" "$field" "$base_file")
                [ "$current" = "$base" ] || {
                    echo "$component changed $field without a version bump" >&2
                    result=1
                    break 2
                }
            done
        fi
    done < <(lock_components)
    rm -f "$base_file"
    return "$result"
}

lock_verify() {
    local against=''
    if [ "${1:-}" = '--against' ]; then
        [ "$#" -eq 2 ] || { echo 'usage: lib-lock.sh verify [--against <git-ref>]' >&2; return 2; }
        against=$2
    elif [ "$#" -ne 0 ]; then
        echo 'usage: lib-lock.sh verify [--against <git-ref>]' >&2
        return 2
    fi

    local component fields line count
    while IFS= read -r component; do
        line=$(lock_line_from_file "$component" "$LOCK_FILE")
        read -ra fields <<<"$line"
        count=${#fields[@]}
        [ "$count" -eq 6 ] || {
            echo "$component lock line must have 6 fields (got $count)" >&2
            return 1
        }
        lock_verify_component "$component"
    done < <(lock_components)
    [ -z "$against" ] || lock_verify_against "$against"
    echo 'upstream.lock verification passed'
}

lock_changed_path() {
    local changed=$1 path=$2 candidate
    while IFS= read -r candidate; do
        [ "$candidate" = "$path" ] || [[ "$candidate" == "$path"/* ]] || continue
        return 0
    done <<<"$changed"
    return 1
}

lock_line_changed() {
    local component=$1 diff=$2 line
    line=$(awk -v component="$component" '{ key = $1; sub(/^[+-]/, "", key); if (key == component) { print; exit } }' <<<"$diff")
    [ -n "$line" ]
}

lock_changes() {
    local base=$1 changed lock_diff component path all_builds=false
    local file_restore=false restore_image=false dedup_plugin=false meta=false
    local smoke=false fixture=false heavy=false input_changed
    if [ -z "$base" ] || [ "$base" = '0000000000000000000000000000000000000000' ]; then
        all_builds=true
        changed='first run'
        lock_diff=''
    else
        changed=$(git -C "$ROOT_DIR" diff --name-only "$base" HEAD)
        lock_diff=$(git -C "$ROOT_DIR" diff "$base" HEAD -- upstream.lock)
    fi
    echo 'changed files:' >&2
    echo "$changed" >&2

    while IFS= read -r component; do
        if [ "$all_builds" = true ] || lock_line_changed "$component" "$lock_diff"; then
            case $component in
                file-restore) file_restore=true ;;
                restore-image) restore_image=true ;;
                dedup-plugin) dedup_plugin=true ;;
                meta) meta=true ;;
            esac
        fi
        input_changed=false
        while IFS= read -r path; do
            if lock_changed_path "$changed" "$path"; then input_changed=true; fi
        done < <(lock_input_paths "$component")
        if [ "$input_changed" = true ]; then
            case $component in
                file-restore) file_restore=true ;;
                restore-image) restore_image=true ;;
                dedup-plugin) dedup_plugin=true ;;
                meta) meta=true ;;
            esac
        fi
    done < <(lock_components)

    if [ "$all_builds" = true ] || lock_changed_path "$changed" '.github/workflows/build.yml'; then
        smoke=true
        fixture=true
    fi
    if lock_changed_path "$changed" 'tests/smoke'; then smoke=true; fi
    if lock_changed_path "$changed" 'tests/fixture'; then fixture=true; fi
    if lock_changed_path "$changed" 'tests/artifacts'; then smoke=true; fixture=true; fi
    if [ "$restore_image" = true ]; then dedup_plugin=true; fi
    if [ "$file_restore" = true ] || [ "$restore_image" = true ]; then smoke=true; fi
    if [ "$dedup_plugin" = true ]; then fixture=true; fi
    if [ "$file_restore" = true ] || [ "$restore_image" = true ] \
        || [ "$dedup_plugin" = true ] || [ "$meta" = true ] \
        || [ "$smoke" = true ] || [ "$fixture" = true ]; then
        heavy=true
    fi

    printf 'file-restore=%s\n' "$file_restore"
    printf 'restore-image=%s\n' "$restore_image"
    printf 'dedup-plugin=%s\n' "$dedup_plugin"
    printf 'meta=%s\n' "$meta"
    printf 'smoke=%s\n' "$smoke"
    printf 'fixture=%s\n' "$fixture"
    printf 'heavy=%s\n' "$heavy"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case ${1:-} in
        verify) shift; lock_verify "$@" ;;
        inputs) [ "$#" -eq 2 ] || { echo 'usage: lib-lock.sh inputs <component>' >&2; exit 2; }; lock_input_paths "$2" ;;
        hash) [ "$#" -eq 2 ] || { echo 'usage: lib-lock.sh hash <component>' >&2; exit 2; }; lock_input_hash "$2" ;;
        changes)
            if [ "${2:-}" != '--base' ] || [ "$#" -ne 3 ]; then
                echo 'usage: lib-lock.sh changes --base <git-ref>' >&2
                exit 2
            fi
            lock_changes "$3"
            ;;
        *) echo 'usage: lib-lock.sh {verify|inputs|hash|changes}' >&2; exit 2 ;;
    esac
fi
