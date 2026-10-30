#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

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
