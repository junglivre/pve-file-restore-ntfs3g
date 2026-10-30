#!/usr/bin/env bash
set -Eeuo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <artifacts-dir>" >&2; exit 2; }
artifacts=$1
find_one() {
    local directory=$1 pattern=$2
    local matches=()
    mapfile -t matches < <(find "$directory" -maxdepth 1 -type f -name "$pattern" -print)
    [ "${#matches[@]}" -eq 1 ] || { echo "expected one $pattern in $directory" >&2; exit 1; }
    printf '%s\n' "${matches[0]}"
}

restore_image=$(find_one "$artifacts/restore-image" 'proxmox-backup-restore-image_*.deb')
file_restore=$(find_one "$artifacts/file-restore" 'proxmox-backup-file-restore_*.deb')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$restore_image" "$tmp/restore-image"
dpkg-deb -x "$file_restore" "$tmp/file-restore"
kernel="$tmp/restore-image/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/bzImage"
initrd="$tmp/restore-image/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img"
mkdir "$tmp/inject"
# The upstream image deliberately omits the daemon. Append a second newc
# archive with the freshly built daemon, matching the PVE restore path.
install -m 0755 \
    "$tmp/file-restore/usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon" \
    "$tmp/inject/proxmox-restore-daemon"
(cd "$tmp/inject" && find . -print0 | cpio --null -o --format=newc) >> "$initrd"

qemu_args=(
    -enable-kvm -m 1024 -nographic -no-reboot
    -kernel "$kernel" -initrd "$initrd" -append 'console=ttyS0'
)
has_vsock=0
if [ -e /dev/vhost-vsock ]; then
    qemu_args+=(-device 'vhost-vsock-pci,guest-cid=3')
    has_vsock=1
fi

log="$tmp/qemu-boot.log"
qemu_pid=0
wait_for_daemon() {
    local attempt
    for ((attempt = 0; attempt < 120; attempt++)); do
        if grep -qF 'setup basic system environment...' "$log"; then
            return 0
        fi
        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

set +e
timeout 120 qemu-system-x86_64 "${qemu_args[@]}" >"$log" 2>&1 &
qemu_pid=$!
set -e

if ! wait_for_daemon; then
    echo 'QEMU did not reach the restore-daemon execution marker' >&2
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    cat "$log"
    exit 1
fi

if [ "$has_vsock" -eq 1 ]; then
    handshake_ok=0
    for ((attempt = 0; attempt < 30; attempt++)); do
        if "$(dirname -- "${BASH_SOURCE[0]}")/assert-boot-log.sh" --handshake \
            >"$tmp/handshake.out" 2>&1; then
            handshake_ok=1
            break
        fi
        sleep 1
    done
    if [ "$handshake_ok" -ne 1 ]; then
        echo 'vsock handshake did not return an HTTP status line' >&2
        cat "$tmp/handshake.out" >&2
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        cat "$log"
        exit 1
    fi
fi

set +e
wait "$qemu_pid"
qemu_rc=$?
set -e
cat "$log"
if [ "$has_vsock" -eq 0 ]; then
    echo 'vhost-vsock unavailable; only daemon execution was checked'
fi
"$(dirname -- "${BASH_SOURCE[0]}")/assert-boot-log.sh" "$log" "$qemu_rc"
"$(dirname -- "${BASH_SOURCE[0]}")/assert-boot-log.sh" "$log" "$qemu_rc"
