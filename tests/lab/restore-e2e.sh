#!/usr/bin/env bash
# Extract every fixture manifest path from a real PBS backup and verify bytes.
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
[ -f "$manifest" ] || { echo "manifest not found: $manifest" >&2; exit 1; }
[ -s "$manifest" ] || { echo 'manifest.sha256 is empty' >&2; exit 1; }
[ -f "$dedup_files" ] || { echo "dedup file list not found: $dedup_files" >&2; exit 1; }

remote_dir="/tmp/pve-file-restore-e2e-$$"
remote_manifest="$remote_dir/manifest.sha256"
remote_dedup_files="$remote_dir/dedup-files.txt"
ssh -F "$ssh_config" "$node" mkdir -m 700 "$remote_dir"
copy_status=0
if scp -q -F "$ssh_config" "$manifest" "$dedup_files" "$node:$remote_dir/"; then
    copy_status=0
else
    copy_status=$?
fi
if [ "$copy_status" -ne 0 ]; then
    ssh -F "$ssh_config" "$node" rm -rf "$remote_dir" </dev/null || true
    exit "$copy_status"
fi

ssh -F "$ssh_config" "$node" bash -s -- "$pbs_storage" "$backup_volid" \
    "$remote_manifest" "$remote_dedup_files" <<'EOF'
set -Eeuo pipefail
pbs_storage=$1
backup_volid=$2
manifest=$3
dedup_file_list=$4
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

archive=$(normalize_restore_path "${PVE_RESTORE_ARCHIVE:-}")
if [ -z "${PVE_RESTORE_ARCHIVE:-}" ]; then
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

partition=${PVE_RESTORE_PARTITION:-}
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

entries="$output_dir/entries"
plain_total=0
manifest_total=0
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
done <"$manifest"

if [ "$dedup_total" -ne 9 ] || [ "$plain_total" -ne 2 ] || [ "$manifest_total" -ne 11 ]; then
    printf 'SETUP ERROR: expected manifest layout dedup 9, plain 2, total 11; got dedup %s, plain %s, total %s\n' \
        "$dedup_total" "$plain_total" "$manifest_total" >&2
    printf 'dedup 0/%s, plain 0/%s\n' "$dedup_total" "$plain_total"
    exit 3
fi

dedup_passed=0
plain_passed=0
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
    if [ "$extract_status" -eq 0 ] && [ -f "$target" ] \
        && printf '%s  %s\n' "$expected" "$target" | sha256sum -c - >/dev/null; then
        verified=true
    fi
    if [ -n "${dedup_paths[$path]+present}" ]; then
        if $verified; then
            dedup_passed=$((dedup_passed + 1))
            printf 'PASS dedup: %s\n' "$path"
        else
            printf 'LOST dedup: %s\n' "$path" >&2
        fi
    elif $verified; then
        plain_passed=$((plain_passed + 1))
        printf 'PASS plain: %s\n' "$path"
    else
        setup_error=true
        printf 'SETUP ERROR: cannot extract or verify non-Dedup file: %s\n' "$path" >&2
    fi
done <"$entries"

printf 'dedup %s/9, plain %s/2\n' "$dedup_passed" "$plain_passed"
if $setup_error; then
    echo 'SETUP ERROR: at least one non-Dedup file could not be extracted; credentials/repository or backup setup is invalid' >&2
    exit 3
fi
[ "$dedup_passed" -eq 9 ] && [ "$plain_passed" -eq 2 ]
EOF
