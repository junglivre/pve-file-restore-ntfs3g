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

printf '%064d  ntfs-dedup.img.zst\n' 0 > "$FIXTURE/ntfs-dedup.img.zst.sha256"
if "$SCRIPT" none "$FIXTURE" > "$TMP/bad-checksum.out" 2>&1; then
    echo 'bad image checksum unexpectedly passed' >&2
    exit 1
fi
grep -qF 'FAILED' "$TMP/bad-checksum.out"

echo 'fixture tests passed'
