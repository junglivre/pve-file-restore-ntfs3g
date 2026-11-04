#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/tests/fixture/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
FIXTURE="$TMP/fixture"
GOOD="$TMP/good"
BAD="$TMP/bad"
mkdir -p "$BIN" "$FIXTURE" "$GOOD" "$BAD"

printf 'compressed fixture placeholder\n' > "$FIXTURE/ntfs-dedup.img.zst"
sha256sum "$FIXTURE/ntfs-dedup.img.zst" | sed "s#  $FIXTURE/#  #" > "$FIXTURE/ntfs-dedup.img.zst.sha256"

mkdir -p "$GOOD/normal" "$GOOD/Dedup path" "$BAD/normal" "$BAD/Dedup path"
printf 'normal content\n' > "$GOOD/normal/file.txt"
cp "$GOOD/normal/file.txt" "$BAD/normal/file.txt"
printf 'deduplicated content\n' > "$GOOD/Dedup path/file.bin"
printf 'wrong content\n' > "$BAD/Dedup path/file.bin"
normal_hash=$(sha256sum "$GOOD/normal/file.txt")
normal_hash=${normal_hash%% *}
dedup_hash=$(sha256sum "$GOOD/Dedup path/file.bin")
dedup_hash=${dedup_hash%% *}
printf '%s  %s\n%s  %s\n' \
    "$normal_hash" 'normal/file.txt' "$dedup_hash" 'Dedup path/file.bin' > "$FIXTURE/manifest.sha256"
printf '%s\n' 'Dedup path/file.bin' > "$FIXTURE/dedup-files.txt"

write_fake() {
    local file=$1
    shift
    printf '%s\n' "$@" > "$file"
    chmod +x "$file"
}

write_fake "$BIN/zstd" \
    '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
    'output='"'"''"'"'' 'input='"'"''"'"'' \
    'while [ "$#" -gt 0 ]; do' \
    "    case \$1 in" \
    "        -o) output=\$2; shift 2 ;;" \
    '        -d|--quiet) shift ;;' \
    "        *) input=\$1; shift ;;" \
    '    esac' \
    'done' \
    "cp \"\$input\" \"\$output\""
write_fake "$BIN/dpkg" \
    '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
    "[ \"\${1:-}\" = -i ] || exit 2" "touch \"\${FAKE_PLUGIN_STATE:?}\""
write_fake "$BIN/ntfs-3g" \
    '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
    "mount_dir=\${!#}" \
    "if [ -e \"\$FAKE_PLUGIN_STATE\" ]; then source_dir=\$FAKE_GOOD_DIR; else source_dir=\$FAKE_BAD_DIR; fi" \
    "cp -a \"\$source_dir/.\" \"\$mount_dir/\"" \
    "touch \"\$mount_dir/.mounted\""
write_fake "$BIN/mountpoint" \
    '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
    "[ \"\${1:-}\" = -q ] && shift" "[ -f \"\${1:?}/.mounted\" ]"
write_fake "$BIN/fusermount3" '#!/usr/bin/env bash' 'set -Eeuo pipefail'
export PATH="$BIN:$PATH"
export FAKE_BAD_DIR="$BAD"
export FAKE_GOOD_DIR="$GOOD"
export FAKE_PLUGIN_STATE="$TMP/plugin-installed"

rm -f "$FAKE_PLUGIN_STATE"
"$SCRIPT" none "$FIXTURE" > "$TMP/without-plugin.out"
grep -qF 'fixture passed without plugin: 1 expected Dedup failures, 2 total entries' \
    "$TMP/without-plugin.out"
: > "$TMP/plugin.deb"
"$SCRIPT" "$TMP/plugin.deb" "$FIXTURE" > "$TMP/with-plugin.out"
grep -qF 'fixture passed with plugin: 2/2 entries OK' "$TMP/with-plugin.out"

cp "$FIXTURE/manifest.sha256" "$TMP/manifest.before"
rm -f "$FAKE_PLUGIN_STATE"
printf '%064d  missing/file.txt\n' 0 > "$FIXTURE/manifest.sha256"
if "$SCRIPT" none "$FIXTURE" > "$TMP/bad-manifest.out" 2>&1; then
    echo 'invalid fixture expectation unexpectedly passed' >&2
    exit 1
fi
grep -qF 'unexpected failing paths' "$TMP/bad-manifest.out"
mv "$TMP/manifest.before" "$FIXTURE/manifest.sha256"

# Large Dedup files: listed in large-files.txt and counted in the summary.
mkdir -p "$GOOD/grande" "$BAD/grande"
head -c 300000 /dev/zero | tr '\0' 'x' > "$GOOD/grande/big.txt"
head -c 1000 /dev/zero | tr '\0' 'x' > "$BAD/grande/big.txt"
big_hash=$(sha256sum "$GOOD/grande/big.txt")
big_hash=${big_hash%% *}
cp "$FIXTURE/manifest.sha256" "$TMP/manifest.small"
cp "$FIXTURE/dedup-files.txt" "$TMP/dedup.small"
printf '%s  %s\n' "$big_hash" 'grande/big.txt' >> "$FIXTURE/manifest.sha256"
printf '%s\n' 'grande/big.txt' >> "$FIXTURE/dedup-files.txt"
printf '%s\n' 'grande/big.txt' > "$FIXTURE/large-files.txt"
"$SCRIPT" "$TMP/plugin.deb" "$FIXTURE" > "$TMP/large.out"
grep -qF 'fixture passed with plugin: 3/3 entries OK, 1/1 large Dedup files' "$TMP/large.out"

# A plugin that truncates big files fails the run.
cp "$BAD/grande/big.txt" "$GOOD/grande/big.txt"
if "$SCRIPT" "$TMP/plugin.deb" "$FIXTURE" > "$TMP/truncated.out" 2>&1; then
    echo 'truncated large file unexpectedly passed' >&2
    exit 1
fi
grep -qF 'FAIL grande/big.txt' "$TMP/truncated.out"

# A read error (EIO) is reported as a failure of that path, not a crash.
write_fake "$BIN/sha256sum" \
    '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    "    case \$arg in */grande/big.txt) echo \"sha256sum: \$arg: Input/output error\" >&2; exit 1 ;; esac" \
    'done' \
    "exec $(command -v sha256sum) \"\$@\""
if "$SCRIPT" "$TMP/plugin.deb" "$FIXTURE" > "$TMP/eio.out" 2>&1; then
    echo 'unreadable large file unexpectedly passed' >&2
    exit 1
fi
grep -qF 'FAIL grande/big.txt (expected '"$big_hash"', got read error: Input/output error)' "$TMP/eio.out"
grep -qF 'expected 0 failures, got 1' "$TMP/eio.out"
rm -f "$BIN/sha256sum" "$FIXTURE/large-files.txt"
mv "$TMP/manifest.small" "$FIXTURE/manifest.sha256"
mv "$TMP/dedup.small" "$FIXTURE/dedup-files.txt"

printf '%064d  ntfs-dedup.img.zst\n' 0 > "$FIXTURE/ntfs-dedup.img.zst.sha256"
if "$SCRIPT" none "$FIXTURE" > "$TMP/bad-checksum.out" 2>&1; then
    echo 'bad image checksum unexpectedly passed' >&2
    exit 1
fi
grep -qF 'FAILED' "$TMP/bad-checksum.out"

echo 'fixture tests passed'
