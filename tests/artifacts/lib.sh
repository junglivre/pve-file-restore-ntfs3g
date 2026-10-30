#!/usr/bin/env bash
set -Eeuo pipefail

deb_relation_has() {
    local deb=$1 field=$2 expected=$3 value
    value=$(dpkg-deb -f "$deb" "$field") || return 1
    awk -v expected="$expected" '
        {
            value = value (value ? " " : "") $0
        }
        END {
            count = split(value, entries, ",")
            for (i = 1; i <= count; i++) {
                entry = entries[i]
                sub(/^[[:space:]]+/, "", entry)
                sub(/[[:space:]]+$/, "", entry)
                if (entry == expected) {
                    found = 1
                    break
                }
            }
            exit !found
        }
    ' <<<"$value"
}
