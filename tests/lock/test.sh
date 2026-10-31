#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SANDBOX="$TMP/repo"
cp -a "$ROOT/." "$SANDBOX"

"$SANDBOX/scripts/lib-lock.sh" verify > "$TMP/verify.out"
grep -qF 'upstream.lock verification passed' "$TMP/verify.out"

sed -E -i '0,/sha256:[0-9a-f]+/s//sha256:deadbeef/' "$SANDBOX/upstream.lock"
if "$SANDBOX/scripts/lib-lock.sh" verify > "$TMP/tampered.out" 2>&1; then
    echo 'tampered lock hash unexpectedly passed' >&2
    exit 1
fi
cp "$ROOT/upstream.lock" "$SANDBOX/upstream.lock"

# Change a package input without changing its version. The same effective lock
# line in the temporary base must reject that change.
git -C "$SANDBOX" init -q
git -C "$SANDBOX" config user.email test@example.invalid
git -C "$SANDBOX" config user.name test
git -C "$SANDBOX" add .
git -C "$SANDBOX" commit -qm baseline
meta_hash=$("$SANDBOX/scripts/lib-lock.sh" hash meta)
# shellcheck disable=SC1090 # the test deliberately sources its isolated copy
source "$SANDBOX/scripts/lib-lock.sh"
meta_version=$(lock_field meta version)
lock_replace_line meta "$meta_version" - - "$meta_hash" https://example.invalid/meta#changed
if "$SANDBOX/scripts/lib-lock.sh" verify --against HEAD > "$TMP/source-change.out" 2>&1; then
    echo 'same-version source change unexpectedly passed' >&2
    exit 1
fi
grep -qF 'changed source without a version bump' "$TMP/source-change.out"
cp "$ROOT/upstream.lock" "$SANDBOX/upstream.lock"
printf '\n# input changed without a version bump\n' >> "$SANDBOX/packaging/pve-file-restore-ntfs3g/control"
if "$SANDBOX/scripts/lib-lock.sh" verify --against HEAD > "$TMP/same-version.out" 2>&1; then
    echo 'same-version packaging change unexpectedly passed' >&2
    exit 1
fi
grep -qF 'inputs hash mismatch' "$TMP/same-version.out"

# A new version makes the same input change admissible after its lock hash is
# refreshed by the helper.
lock_update meta 2.1.8 - - -
if "$SANDBOX/scripts/lib-lock.sh" verify --against HEAD > "$TMP/bumped.out" 2>&1; then
    :
else
    cat "$TMP/bumped.out" >&2
    exit 1
fi
grep -qF 'upstream.lock verification passed' "$TMP/bumped.out"

echo 'lock tests passed'
