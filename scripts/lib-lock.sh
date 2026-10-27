#!/usr/bin/env bash
# Parser for upstream.lock. Source this file, then call lock_field.
#
#   lock_field <component> <version|commit|rev|patches_sha256>

lock_field() {
    local component=$1 field=$2
    local lock_file
    lock_file=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/upstream.lock
    local line
    line=$(grep -E "^${component}[[:space:]]" "$lock_file") || {
        echo "component '$component' not found in upstream.lock" >&2
        return 1
    }
    local _c version commit rev hash
    read -r _c version commit rev hash <<<"$line"
    case $field in
        version) printf '%s\n' "$version" ;;
        commit) printf '%s\n' "$commit" ;;
        rev) printf '%s\n' "$rev" ;;
        patches_sha256) printf '%s\n' "${hash#sha256:}" ;;
        *)
            echo "unknown lock field '$field'" >&2
            return 1
            ;;
    esac
}
