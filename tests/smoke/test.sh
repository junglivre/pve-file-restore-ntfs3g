#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/tests/smoke/assert-boot-log.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_expect_pass() {
    local log=$1 rc=$2
    "$SCRIPT" "$ROOT/tests/smoke/fixtures/$log" "$rc" >"$TMP/$log.out"
}

run_expect_fail() {
    local log=$1 rc=$2
    if "$SCRIPT" "$ROOT/tests/smoke/fixtures/$log" "$rc" \
        >"$TMP/$log.out" 2>&1; then
        echo "$log with rc $rc unexpectedly passed" >&2
        exit 1
    fi
}

run_expect_pass daemon-ran.log 124
run_expect_fail init-only.log 124
run_expect_fail panic.log 124
run_expect_fail setup-failed.log 124
run_expect_fail daemon-ran.log 0
run_expect_fail daemon-ran.log 125

fake_bin="$TMP/fake-bin"
mkdir "$fake_bin"
cat >"$fake_bin/socat" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "$*" = '- VSOCK-CONNECT:3:807' ]
cat >/dev/null
printf 'HTTP/1.1 401 Unauthorized\nContent-Length: 0\n\n'
EOF
chmod 0755 "$fake_bin/socat"
if ! PATH="$fake_bin:$PATH" "$SCRIPT" --handshake >"$TMP/handshake.out"; then
    echo 'fake vsock handshake unexpectedly failed' >&2
    exit 1
fi

echo 'smoke tests passed'
