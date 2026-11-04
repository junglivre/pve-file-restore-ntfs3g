#!/usr/bin/env bash
# Build an OS-less PVE VM whose only disk contains the fixture partition, then
# back it up to the lab PBS. Run this on the lab operator workstation.
set -Eeuo pipefail
export PATH=/usr/sbin:/sbin:$PATH

usage() {
    echo "usage: $0 <node> <vmid> <image-storage> <fixture-dir>" >&2
    exit 2
}
[ "$#" -eq 4 ] || usage

node=$1
vmid=$2
image_storage=$3
fixture=$4
ssh_config=${PVE_SSH_CONFIG:-"$HOME/.config/pve-lab/ssh_config"}
pbs_storage=${PVE_PBS_STORAGE:-pbs-lab}

[ "$vmid" -ge 100 ] 2>/dev/null || { echo 'vmid must be an integer >= 100' >&2; exit 2; }
[ -n "$image_storage" ] || { echo 'image-storage must not be empty' >&2; exit 2; }
[ -d "$fixture" ] || { echo "fixture directory not found: $fixture" >&2; exit 1; }
for required in ntfs-dedup.img.zst ntfs-dedup.img.zst.sha256 manifest.sha256 dedup-files.txt; do
    [ -f "$fixture/$required" ] || { echo "missing fixture asset: $fixture/$required" >&2; exit 1; }
done
(cd "$fixture" && sha256sum -c ntfs-dedup.img.zst.sha256)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
zstd -dc "$fixture/ntfs-dedup.img.zst" >"$work/partition.img"
partition_bytes=$(stat -c '%s' "$work/partition.img")
[ "$((partition_bytes % 512))" -eq 0 ] || {
    echo 'decompressed fixture is not a whole number of 512-byte sectors' >&2
    exit 1
}
partition_sectors=$((partition_bytes / 512))
partition_sha256=$(sha256sum "$work/partition.img" | awk '{print $1}')
partition_start=2048
partition_end=$((partition_start + partition_sectors - 1))
disk_sectors=$(( ((partition_end + 2048) / 2048) * 2048 + 34 ))
truncate -s "$((disk_sectors * 512))" "$work/disk.raw"
printf 'label: gpt\nunit: sectors\n\nstart=%s, size=%s, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' \
    "$partition_start" "$partition_sectors" \
    | sfdisk "$work/disk.raw" >/dev/null
dd if="$work/partition.img" of="$work/disk.raw" bs=512 seek="$partition_start" \
    conv=notrunc status=none
actual_partition_sha256=$(dd if="$work/disk.raw" bs=512 skip="$partition_start" \
    count="$partition_sectors" status=none | sha256sum | awk '{print $1}')
[ "$actual_partition_sha256" = "$partition_sha256" ] || {
    echo 'local GPT partition does not match decompressed fixture' >&2
    exit 1
}

ssh_opts=(-F "$ssh_config")
remote_image="/tmp/ntfs-dedup-${vmid}.raw"
scp "${ssh_opts[@]}" "$work/disk.raw" "$node:$remote_image"
ssh "${ssh_opts[@]}" "$node" bash -s -- "$vmid" "$remote_image" "$image_storage" \
    "$pbs_storage" "$partition_start" "$partition_sectors" "$partition_sha256" <<'EOF'
set -Eeuo pipefail
vmid=$1
remote_image=$2
image_storage=$3
pbs_storage=$4
partition_start=$5
partition_sectors=$6
expected_partition_sha256=$7
vm_created=false
cleanup() {
    status=$?
    rm -f "$remote_image"
    if [ "$status" -ne 0 ] && [ "$vm_created" = true ]; then
        echo "cleaning up VM $vmid created by this run" >&2
        qm destroy "$vmid" --purge 1 >/dev/null 2>&1 ||
            echo "warning: could not destroy failed VM $vmid" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

if qm config "$vmid" >/dev/null 2>&1; then
    echo "refusing to use existing VM $vmid; this script will not touch it" >&2
    exit 1
fi

if qm create "$vmid" --name "ntfs-dedup-$vmid" --ostype l26 --memory 512 --cores 1 \
    --scsihw virtio-scsi-pci --onboot 0; then
    vm_created=true
else
    create_status=$?
    if qm config "$vmid" >/dev/null 2>&1; then
        vm_created=true
    fi
    exit "$create_status"
fi
qm importdisk "$vmid" "$remote_image" "$image_storage" --format raw >/dev/null
volid=$(qm config "$vmid" | awk '$1 == "unused0:" { print $2; exit }')
[ -n "$volid" ] || { echo 'qm importdisk did not create an unused disk' >&2; exit 1; }
qm set "$vmid" --scsi0 "$volid" >/dev/null
disk_path=$(pvesm path "$volid")
actual_partition_sha256=$(dd if="$disk_path" bs=512 skip="$partition_start" \
    count="$partition_sectors" status=none | sha256sum | awk '{print $1}')
[ "$actual_partition_sha256" = "$expected_partition_sha256" ] || {
    echo 'PVE disk partition does not match decompressed fixture' >&2
    exit 1
}
disk_count=$(qm config "$vmid" | awk '/^(ide|sata|scsi|virtio)[0-9]+:/ { count++ } END { print count + 0 }')
[ "$disk_count" -eq 1 ] || { echo "expected exactly one VM disk, got $disk_count" >&2; exit 1; }

vzdump "$vmid" --storage "$pbs_storage" --mode stop --compress zstd --remove 0
node_name=$(hostname -s)
backup_volid=$(pvesh get "/nodes/$node_name/storage/$pbs_storage/content" \
    --content backup --vmid "$vmid" --output-format json \
    | python3 -c '
import json, sys
items = json.load(sys.stdin)
items.sort(key=lambda item: item.get("ctime", 0), reverse=True)
if not items:
    raise SystemExit("backup volume was not listed")
print(items[0]["volid"])
')
printf 'backup-volid: %s\n' "$backup_volid"
EOF
