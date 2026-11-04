#!/usr/bin/env bash
# Extract every fixture manifest path from a real PBS backup and verify bytes.
#
# The fixture directory holds manifest.sha256 (every file), dedup-files.txt
# (the Dedup reparse-point paths) and, optionally, large-files.txt (Dedup files
# of 100 MiB or more, which span several windows of the plugin's stream map).
# Non-Dedup files, when the fixture has any, prove that the backup and
# credentials work: if one of them fails the run is a setup error (rc 3).
#
# PVE_RESTORE_ARCHIVE and PVE_RESTORE_PARTITION (for example
# /drive-sata1.img.fidx and /drive-sata1.img.fidx/part/2) select the disk and
# partition when the backup has more than one; by default the only ones are used.
set -Eeuo pipefail

usage() {
    echo "usage: $0 <node> <pbs-storage> <backup-volid> <fixture-dir>" >&2
    exit 2
}
[ "$#" -eq 4 ] || usage

node=$1
pbs_storage=$2
backup_volid=$3
fixture=$4
ssh_config=${PVE_SSH_CONFIG:-"$HOME/.config/pve-lab/ssh_config"}
manifest=$fixture/manifest.sha256
dedup_files=$fixture/dedup-files.txt
large_files=$fixture/large-files.txt
[ -f "$manifest" ] || { echo "manifest not found: $manifest" >&2; exit 1; }
[ -s "$manifest" ] || { echo 'manifest.sha256 is empty' >&2; exit 1; }
[ -f "$dedup_files" ] || { echo "dedup file list not found: $dedup_files" >&2; exit 1; }
lists=("$manifest" "$dedup_files")
if [ -f "$large_files" ]; then
    lists+=("$large_files")
fi

remote_dir="/tmp/pve-file-restore-e2e-$$"
remote_manifest="$remote_dir/manifest.sha256"
remote_dedup_files="$remote_dir/dedup-files.txt"
remote_large_files="$remote_dir/large-files.txt"
ssh -F "$ssh_config" "$node" mkdir -m 700 "$remote_dir"
copy_status=0
if scp -q -F "$ssh_config" "${lists[@]}" "$node:$remote_dir/"; then
    copy_status=0
else
    copy_status=$?
fi
if [ "$copy_status" -ne 0 ]; then
    ssh -F "$ssh_config" "$node" rm -rf "$remote_dir" </dev/null || true
    exit "$copy_status"
fi

# ssh does not pass the environment: the restore selection goes as arguments,
# "-" for automatic (ssh joins the arguments into one line, so an empty one
# would disappear).
ssh -F "$ssh_config" "$node" bash -s -- "$pbs_storage" "$backup_volid" \
    "$remote_manifest" "$remote_dedup_files" "$remote_large_files" \
    "${PVE_RESTORE_ARCHIVE:--}" "${PVE_RESTORE_PARTITION:--}" <<'EOF'
set -Eeuo pipefail
pbs_storage=$1
backup_volid=$2
manifest=$3
dedup_file_list=$4
large_file_list=$5
restore_archive=$6
restore_partition=$7
[ "$restore_archive" != - ] || restore_archive=''
[ "$restore_partition" != - ] || restore_partition=''
output_dir=$(mktemp -d)
storage_block=''
trap 'rm -rf "$output_dir" "$(dirname "$manifest")"' EXIT

storage_block=$(awk -v storage="$pbs_storage" '
$0 ~ /^[^[:space:]]/ {
    if ($1 == "pbs:") {
        inside = ($2 == storage)
        next
    }
    if (inside) {
        exit
    }
}
inside { print }
' /etc/pve/storage.cfg)
[ -n "$storage_block" ] || {
    echo "SETUP ERROR: PBS storage '$pbs_storage' is not defined as a pbs storage" >&2
    exit 3
}

storage_value() {
    local key=$1
    awk -v key="$key" '$1 == key { $1 = ""; sub(/^[[:space:]]+/, "", $0); print; exit }' \
        <<<"$storage_block"
}

server=$(storage_value server)
port=$(storage_value port)
datastore=$(storage_value datastore)
namespace=$(storage_value namespace)
username=$(storage_value username)
fingerprint=$(storage_value fingerprint)
port=${port:-8007}
[ -n "$server" ] && [ -n "$datastore" ] && [ -n "$username" ] && [ -n "$fingerprint" ] || {
    echo "SETUP ERROR: PBS storage '$pbs_storage' lacks server, datastore, username, or fingerprint" >&2
    exit 3
}
password_file="/etc/pve/priv/storage/$pbs_storage.pw"
[ -r "$password_file" ] || {
    echo "SETUP ERROR: PBS password/token file is missing for '$pbs_storage'" >&2
    exit 3
}
password=$(<"$password_file")
[ -n "$password" ] || {
    echo "SETUP ERROR: PBS password/token file is empty for '$pbs_storage'" >&2
    exit 3
}

if [ "$port" = 8007 ]; then
    repository="${username}@${server}:${datastore}"
else
    repository="${username}@${server}:${port}:${datastore}"
fi
export PBS_REPOSITORY="$repository"
export PBS_PASSWORD="$password"
export PBS_FINGERPRINT="$fingerprint"
if [ -n "$namespace" ]; then
    export PBS_NAMESPACE="$namespace"
fi

case "$backup_volid" in
    "$pbs_storage":*) snapshot=${backup_volid#"$pbs_storage:"} ;;
    *) snapshot=$backup_volid ;;
esac
case "$snapshot" in
    backup/*) snapshot=${snapshot#backup/} ;;
esac

normalize_restore_path() {
    local path=$1
    path=/${path#/}
    printf '%s\n' "${path%/}"
}

decode_list() {
    local list_json=$1
    python3 - "$list_json" <<'PY'
import base64
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)

if isinstance(payload, dict):
    entries = payload.get("data", payload.get("entries", []))
    if isinstance(entries, dict):
        entries = [entries]
elif isinstance(payload, list):
    entries = payload
else:
    raise SystemExit("list output is not an array")

for entry in entries:
    encoded = entry.get("filepath")
    entry_type = entry.get("type")
    if not isinstance(encoded, str) or not isinstance(entry_type, str):
        raise SystemExit("list entry lacks filepath or type")
    padding = "=" * (-len(encoded) % 4)
    filepath = base64.b64decode(encoded + padding, validate=True).decode()
    print(f"{entry_type}\t{filepath}")
PY
}

list_directory() {
    local directory=$1
    local list_json=$2
    local list_status=0
    if proxmox-file-restore list "$snapshot" "$directory" --output-format json >"$list_json"; then
        list_status=0
    else
        list_status=$?
    fi
    if [ "$list_status" -ne 0 ]; then
        echo "SETUP ERROR: cannot list restore path '$directory'" >&2
        exit 3
    fi
    if ! decode_list "$list_json"; then
        echo "SETUP ERROR: invalid list output for restore path '$directory'" >&2
        exit 3
    fi
}

archive=$(normalize_restore_path "$restore_archive")
if [ -z "$restore_archive" ]; then
    root_list="$output_dir/root-list.json"
    root_entries="$output_dir/root-entries.tsv"
    list_directory / "$root_list" >"$root_entries"
    mapfile -t archive_candidates < <(
        awk -F '\t' '$1 == "v" && $2 ~ /\.img\.fidx\/?$/ { print $2 }' "$root_entries"
    )
    if [ "${#archive_candidates[@]}" -ne 1 ]; then
        echo "SETUP ERROR: expected exactly one block archive, found ${#archive_candidates[@]}" >&2
        exit 3
    fi
    archive=$(normalize_restore_path "${archive_candidates[0]}")
fi

partition=$restore_partition
if [ -z "$partition" ]; then
    archive_list="$output_dir/archive-list.json"
    archive_entries="$output_dir/archive-entries.tsv"
    list_directory "$archive" "$archive_list" >"$archive_entries"
    mapfile -t partition_container_candidates < <(
        awk -F '\t' '$1 == "v" && $2 ~ /\/part\/?$/ { print $2 }' "$archive_entries"
    )
    if [ "${#partition_container_candidates[@]}" -ne 1 ]; then
        echo "SETUP ERROR: expected exactly one partition container, found ${#partition_container_candidates[@]}" >&2
        exit 3
    fi
    partition_container=$(normalize_restore_path "${partition_container_candidates[0]}")
    partition_list="$output_dir/partition-list.json"
    partition_entries="$output_dir/partition-entries.tsv"
    list_directory "$partition_container" "$partition_list" >"$partition_entries"
    mapfile -t partition_candidates < <(
        awk -F '\t' '$1 == "d" && $2 ~ /\/[0-9]+\/?$/ { print $2 }' "$partition_entries"
    )
    if [ "${#partition_candidates[@]}" -ne 1 ]; then
        echo "SETUP ERROR: expected exactly one partition, found ${#partition_candidates[@]}" >&2
        exit 3
    fi
    partition=$(normalize_restore_path "${partition_candidates[0]}")
else
    partition=$(normalize_restore_path "$partition")
fi
printf 'restore archive: %s\n' "$archive"
printf 'restore partition: %s\n' "$partition"

declare -A dedup_paths=()
dedup_total=0
while IFS= read -r dedup_path; do
    dedup_path=${dedup_path%$'\r'}
    [ -n "$dedup_path" ] || continue
    if [ -n "${dedup_paths[$dedup_path]+present}" ]; then
        echo "SETUP ERROR: duplicate Dedup path: $dedup_path" >&2
        exit 3
    fi
    dedup_paths["$dedup_path"]=1
    dedup_total=$((dedup_total + 1))
done <"$dedup_file_list"

declare -A large_paths=()
large_total=0
if [ -f "$large_file_list" ]; then
    while IFS= read -r large_path; do
        large_path=${large_path%$'\r'}
        [ -n "$large_path" ] || continue
        if [ -z "${dedup_paths[$large_path]+present}" ]; then
            echo "SETUP ERROR: large file is not a Dedup path: $large_path" >&2
            exit 3
        fi
        large_paths["$large_path"]=1
        large_total=$((large_total + 1))
    done <"$large_file_list"
fi

entries="$output_dir/entries"
plain_total=0
manifest_total=0
large_listed=0
while IFS=' ' read -r expected path; do
    [ -n "$expected" ] || continue
    [ -n "$path" ] || { echo 'SETUP ERROR: invalid manifest line' >&2; exit 3; }
    case "$path" in
        /*|../*|*/../*|./*|*/./*) echo "SETUP ERROR: unsafe manifest path: $path" >&2; exit 3 ;;
    esac
    printf '%s\t%s\n' "$expected" "$path" >>"$entries"
    manifest_total=$((manifest_total + 1))
    if [ -z "${dedup_paths[$path]+present}" ]; then
        plain_total=$((plain_total + 1))
    fi
    if [ -n "${large_paths[$path]+present}" ]; then
        large_listed=$((large_listed + 1))
    fi
done <"$manifest"

# Every Dedup and large path must be in the manifest, or the fixture
# directory is not the one the backup was made from.
if [ "$dedup_total" -lt 1 ] || [ "$((manifest_total - plain_total))" -ne "$dedup_total" ] \
    || [ "$large_listed" -ne "$large_total" ]; then
    printf 'SETUP ERROR: inconsistent fixture: %s Dedup paths (%s in the manifest), %s large paths (%s in the manifest)\n' \
        "$dedup_total" "$((manifest_total - plain_total))" "$large_total" "$large_listed" >&2
    exit 3
fi
printf 'fixture layout: dedup %s (large %s), plain %s, total %s\n' \
    "$dedup_total" "$large_total" "$plain_total" "$manifest_total"

dedup_passed=0
plain_passed=0
large_passed=0
setup_error=false
while IFS=$'\t' read -r expected path; do
    # `extract` treats its target as a directory and writes the file inside it
    # under its own name, so give each file a fresh directory.
    target_dir="$output_dir/$path.d"
    target="$target_dir/${path##*/}"
    restore_path="$partition/$path"
    mkdir -p "$target_dir"
    extract_status=0
    if proxmox-file-restore extract "$snapshot" "$restore_path" "$target_dir" >/dev/null; then
        extract_status=0
    else
        extract_status=$?
    fi
    verified=false
    got='missing'
    if [ "$extract_status" -ne 0 ]; then
        got="extract rc $extract_status"
    elif [ -f "$target" ]; then
        got=$(sha256sum "$target")
        got="${got%% *} $(stat -c %s "$target") bytes"
        [ "${got%% *}" != "$expected" ] || verified=true
    fi
    # Big files are checked one at a time; do not keep gigabytes on the node.
    rm -rf "$target_dir"
    kind=dedup
    [ -z "${large_paths[$path]+present}" ] || kind='dedup large'
    if [ -n "${dedup_paths[$path]+present}" ]; then
        if $verified; then
            dedup_passed=$((dedup_passed + 1))
            [ -z "${large_paths[$path]+present}" ] || large_passed=$((large_passed + 1))
            printf 'PASS %s: %s (%s)\n' "$kind" "$path" "$got"
        else
            printf 'LOST %s: %s (expected %s, got %s)\n' "$kind" "$path" "$expected" "$got" >&2
        fi
    elif $verified; then
        plain_passed=$((plain_passed + 1))
        printf 'PASS plain: %s (%s)\n' "$path" "$got"
    else
        setup_error=true
        printf 'SETUP ERROR: cannot extract or verify non-Dedup file: %s (%s)\n' "$path" "$got" >&2
    fi
done <"$entries"

printf 'dedup %s/%s (large %s/%s), plain %s/%s\n' "$dedup_passed" "$dedup_total" \
    "$large_passed" "$large_total" "$plain_passed" "$plain_total"
if $setup_error; then
    echo 'SETUP ERROR: at least one non-Dedup file could not be extracted; credentials/repository or backup setup is invalid' >&2
    exit 3
fi
[ "$dedup_passed" -eq "$dedup_total" ] && [ "$plain_passed" -eq "$plain_total" ]
EOF
