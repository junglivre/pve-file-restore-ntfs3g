#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <artifacts-dir> [component ...]" >&2; exit 2; }
artifacts=$1
shift

selected=()
for component in "$@"; do
    case $component in
        file-restore|restore-image|dedup-plugin|meta) selected+=("$component") ;;
        *) echo "unknown component: $component" >&2; exit 2 ;;
    esac
done

selected_component() {
    local candidate=$1 component
    for component in "${selected[@]}"; do
        [ "$component" = "$candidate" ] && return 0
    done
    return 1
}

find_one() {
    local directory=$1 pattern=$2
    local matches=()
    mapfile -t matches < <(find "$directory" -maxdepth 1 -type f -name "$pattern" -print)
    [ "${#matches[@]}" -eq 1 ] || {
        echo "expected exactly one $pattern in $directory" >&2
        exit 1
    }
    printf '%s\n' "${matches[0]}"
}

for component in file-restore restore-image dedup-plugin meta; do
    directory="$artifacts/$component"
    sums="$artifacts/$component/SHA256SUMS"
    [ -f "$sums" ] || { echo "missing SHA256SUMS for $component" >&2; exit 1; }
    debs=()
    mapfile -t debs < <(find "$directory" -maxdepth 1 -type f -name '*.deb' -printf '%f\n')
    [ "${#debs[@]}" -gt 0 ] || { echo "no .deb assets for $component" >&2; exit 1; }

    listed=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        filename=${line#*  }
        case $filename in
            ''|*/*) echo "invalid checksum asset name for $component: $filename" >&2; exit 1 ;;
        esac
        found=0
        for deb in "${debs[@]}"; do
            if [ "$filename" = "$deb" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] || {
            echo "checksum asset is not a .deb for $component: $filename" >&2
            exit 1
        }
        listed+=("$filename")
    done < "$sums"
    [ "${#listed[@]}" -eq "${#debs[@]}" ] || {
        echo "SHA256SUMS does not cover exactly the .deb assets for $component" >&2
        exit 1
    }
    (cd "$directory" && sha256sum -c SHA256SUMS)

    if selected_component "$component"; then
        case $component in
            file-restore)
                file_restore=$(find_one "$directory" 'proxmox-backup-file-restore_*.deb')
                "$(dirname -- "${BASH_SOURCE[0]}")/file-restore.sh" "$file_restore"
                ;;
            restore-image)
                restore_image=$(find_one "$directory" 'proxmox-backup-restore-image_*.deb')
                "$(dirname -- "${BASH_SOURCE[0]}")/restore-image.sh" "$restore_image"
                ;;
            meta)
                meta=$(find_one "$directory" 'pve-file-restore-ntfs3g_*.deb')
                "$(dirname -- "${BASH_SOURCE[0]}")/meta.sh" "$meta"
                ;;
        esac
    fi
done

echo 'artifact checks passed'
