#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "usage: $0 <plugin.deb|none> <fixture-dir>" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
plugin=$1
fixture=$2

[ "$plugin" = none ] || [ -f "$plugin" ] || {
    echo "plugin package not found: $plugin" >&2
    exit 1
}
[ -d "$fixture" ] || { echo "fixture directory not found: $fixture" >&2; exit 1; }

image_zst="$fixture/ntfs-dedup.img.zst"
image_sum="$fixture/ntfs-dedup.img.zst.sha256"
manifest="$fixture/manifest.sha256"
dedup_files="$fixture/dedup-files.txt"
for required in "$image_zst" "$image_sum" "$manifest" "$dedup_files"; do
    [ -f "$required" ] || { echo "missing fixture asset: $required" >&2; exit 1; }
done

(cd "$fixture" && sha256sum -c ntfs-dedup.img.zst.sha256)

[ -s "$manifest" ] || { echo 'manifest.sha256 is empty' >&2; exit 1; }
[ -s "$dedup_files" ] || { echo 'dedup-files.txt is empty' >&2; exit 1; }

declare -A dedup=()
dedup_count=0
while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || { echo 'dedup-files.txt contains an empty path' >&2; exit 1; }
    [ "${path#/}" = "$path" ] || { echo "absolute Dedup path: $path" >&2; exit 1; }
    case "/$path/" in
        */../*|*/./*) echo "unsafe Dedup path: $path" >&2; exit 1 ;;
    esac
    [ -z "${dedup[$path]+set}" ] || { echo "duplicate Dedup path: $path" >&2; exit 1; }
    dedup[$path]=1
    dedup_count=$((dedup_count + 1))
done < "$dedup_files"

TMP=$(mktemp -d)
MOUNT_DIR=''
UNMOUNT=''
unmount_args=()
cleanup() {
    if [ -n "$MOUNT_DIR" ] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        "$UNMOUNT" "${unmount_args[@]}" "$MOUNT_DIR"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
image="$TMP/ntfs-dedup.img"
mount_dir="$TMP/mount"
mkdir -p "$mount_dir"
zstd -d --quiet "$image_zst" -o "$image"

if [ "$plugin" != none ]; then
    dpkg -i "$plugin"
fi

MOUNT_DIR=$mount_dir
if command -v fusermount3 >/dev/null 2>&1; then
    UNMOUNT=fusermount3
    unmount_args=(-u)
else
    UNMOUNT=umount
fi

ntfs-3g -o ro "$image" "$mount_dir"
mountpoint -q "$mount_dir" || { echo 'ntfs-3g did not mount the fixture' >&2; exit 1; }

manifest_count=0
fail_count=0
unexpected_failures=()
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([[:xdigit:]]{64})\ \ (.+)$ ]] || {
        echo "invalid manifest line: $line" >&2
        exit 1
    }
    expected=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    [ "${path#/}" = "$path" ] || { echo "absolute manifest path: $path" >&2; exit 1; }
    case "/$path/" in
        */../*|*/./*) echo "unsafe manifest path: $path" >&2; exit 1 ;;
    esac
    manifest_count=$((manifest_count + 1))
    file="$mount_dir/$path"
    actual='missing'
    if [ -f "$file" ]; then
        actual=$(sha256sum -- "$file")
        actual=${actual%% *}
    fi
    if [ "$actual" = "$expected" ]; then
        echo "OK $path"
    else
        echo "FAIL $path (expected $expected, got $actual)"
        fail_count=$((fail_count + 1))
        if [ -z "${dedup[$path]+set}" ] || [ "$plugin" != none ]; then
            unexpected_failures+=("$path")
        fi
    fi
done < "$manifest"

if [ "$plugin" = none ]; then
    expected_failures=$dedup_count
else
    expected_failures=0
fi
[ "$manifest_count" -gt 0 ] || { echo 'manifest has no entries' >&2; exit 1; }
[ "$fail_count" -eq "$expected_failures" ] || {
    echo "expected $expected_failures failures, got $fail_count" >&2
    exit 1
}
[ "${#unexpected_failures[@]}" -eq 0 ] || {
    printf 'unexpected failing paths:\n%s\n' "${unexpected_failures[*]}" >&2
    exit 1
}
if [ "$plugin" = none ]; then
    echo "fixture passed without plugin: $fail_count expected Dedup failures, $manifest_count total entries"
else
    echo "fixture passed with plugin: $manifest_count/$manifest_count entries OK"
fi
