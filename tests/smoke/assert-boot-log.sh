#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "usage: $0 <qemu-log> <qemu-rc> | --handshake" >&2
    exit 2
}

[ "${1:-}" = '--handshake' ] && {
    [ "$#" -eq 1 ] || usage
    response=$(printf '%s\n' \
        'GET /api2/json/status HTTP/1.1' \
        'Host: localhost' \
        'Connection: close' \
        '' | socat - VSOCK-CONNECT:3:807)
    if ! grep -Eq '^HTTP/[0-9.]+[[:space:]]+[0-9]{3}([[:space:]]|$)' <<<"$response"; then
        echo 'vsock handshake returned no HTTP status line' >&2
        exit 1
    fi
    echo 'vsock handshake passed'
    exit 0
}

[ "$#" -eq 2 ] || usage
log=$1
qemu_rc=$2

[ -s "$log" ] || { echo "QEMU log is missing or empty: $log" >&2; exit 1; }
[ "$qemu_rc" -eq 124 ] || {
    echo "QEMU must be killed by timeout with rc 124; got rc $qemu_rc" >&2
    exit 1
}

if grep -Eiq 'kernel panic|/proxmox-restore-daemon missing from image' "$log"; then
    echo 'QEMU boot log contains a panic or missing-daemon failure' >&2
    exit 1
fi

if grep -qF 'system environment setup failed' "$log"; then
    echo 'QEMU boot log reports restore-daemon environment setup failure' >&2
    exit 1
fi

if ! grep -qF 'setup basic system environment...' "$log"; then
    echo 'QEMU boot log has no restore-daemon execution marker' >&2
    exit 1
fi

echo 'boot smoke passed: daemon execution checked'
