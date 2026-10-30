#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

base=origin/master
while [ "$#" -gt 0 ]; do
    case $1 in
        --base) [ "$#" -ge 2 ] || { echo 'usage: run-all.sh [--base <git-ref>]' >&2; exit 2; }; base=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

failures=0
tests=(tests/*/test.sh)

run_test() {
    local test=$1
    echo
    echo "===== $test ====="
    if "$ROOT/$test"; then
        echo "PASS: $test"
    else
        echo "FAIL: $test" >&2
        failures=$((failures + 1))
    fi
}

echo '===== tests/lint.sh ====='
if tests/lint.sh; then
    echo 'PASS: tests/lint.sh'
else
    echo 'FAIL: tests/lint.sh' >&2
    failures=$((failures + 1))
fi

echo
echo "===== scripts/lib-lock.sh verify --against $base ====="
if scripts/lib-lock.sh verify --against "$base"; then
    echo 'PASS: scripts/lib-lock.sh verify'
else
    echo 'FAIL: scripts/lib-lock.sh verify' >&2
    failures=$((failures + 1))
fi

for test in "${tests[@]}"; do
    run_test "$test"
done

echo
if [ "$failures" -eq 0 ]; then
    echo "all tests passed (${#tests[@]} unit test suites plus lint)"
else
    echo "$failures test suite(s) failed" >&2
    exit 1
fi
