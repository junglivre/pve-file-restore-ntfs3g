#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

while IFS= read -r patch_file; do
    git -C "$ROOT" apply --stat -- "$patch_file" >/dev/null
done < <(find "$ROOT/patches" -type f -name '*.patch' -print | sort)

SANDBOX="$TMP/repo"
cp -a "$ROOT/." "$SANDBOX"

upstream="$TMP/upstream"
git init -q "$upstream"
git -C "$upstream" config user.email test@example.invalid
git -C "$upstream" config user.name test
printf 'old\n' > "$upstream/hello"
git -C "$upstream" add hello
git -C "$upstream" commit -qm base
base=$(git -C "$upstream" rev-parse HEAD)
printf 'tip\n' > "$upstream/hello"
git -C "$upstream" commit -qam tip
tip=$(git -C "$upstream" rev-parse HEAD)

mkdir -p "$SANDBOX/patches/next"
cat > "$SANDBOX/patches/current.patch" <<'EOF'
diff --git a/hello b/hello
index 3367afd..3f2c8e4 100644
--- a/hello
+++ b/hello
@@ -1 +1 @@
-old
+patched
EOF
cat > "$SANDBOX/patches/next/file-restore.patch" <<'EOF'
diff --git a/hello b/hello
index 3367afd..3f2c8e4 100644
--- a/hello
+++ b/hello
@@ -1 +1 @@
-tip
+patched
EOF

# shellcheck disable=SC1090 # the test deliberately sources its isolated copy
source "$SANDBOX/scripts/lib-lock.sh"
lock_replace_line file-restore 1.0 "$base" patches/current.patch deadbeef "$upstream#master"
lock_replace_line restore-image 1.0 - - deadbeef -
lock_replace_line dedup-plugin 1.0 - - deadbeef -
lock_replace_line meta 1.0 - - deadbeef -

locked_work="$TMP/locked"
mkdir -p "$locked_work"
# shellcheck disable=SC1090 # the test deliberately sources its isolated copy
source "$SANDBOX/scripts/lib-patch.sh"
patch_prepare_tree file-restore "$locked_work/source" locked
patch_apply_locked file-restore "$locked_work/source"
grep -qx 'patched' "$locked_work/source/hello"

tip_output=$(cd "$SANDBOX" && scripts/check-patches.sh --tip)
grep -qF "file-restore: selected patches/next/file-restore.patch at tip" <<<"$tip_output"
tip_output=$(cd "$SANDBOX" && scripts/check-patches.sh --commit "$tip")
grep -qF "file-restore: selected patches/next/file-restore.patch at $tip" <<<"$tip_output"

if (cd "$SANDBOX" && scripts/check-patches.sh --commit "$base" >/dev/null); then
    :
else
    echo 'locked commit selection unexpectedly failed' >&2
    exit 1
fi

rm "$SANDBOX/patches/next/file-restore.patch"
cat > "$SANDBOX/patches/first-fails.patch" <<'EOF'
diff --git a/hello b/hello
index 3367afd..3f2c8e4 100644
--- a/hello
+++ b/hello
@@ -1 +1 @@
-absent
+patched
EOF
cat > "$SANDBOX/patches/second-applies.patch" <<'EOF'
diff --git a/hello b/hello
index 3367afd..3f2c8e4 100644
--- a/hello
+++ b/hello
@@ -1 +1 @@
-tip
+patched
EOF

second_work="$TMP/second"
mkdir -p "$second_work"
patch_prepare_tree file-restore "$second_work/source" tip
patch_apply_paths file-restore "$second_work/source" patches/second-applies.patch
grep -qx 'patched' "$second_work/source/hello"
lock_replace_line file-restore 1.0 "$base" first-fails.patch,second-applies.patch deadbeef "$upstream#master"
if patch_select_paths file-restore tip >/dev/null 2>&1; then
    echo 'selection ignored a failed first patch' >&2
    exit 1
fi
if (cd "$SANDBOX" && scripts/check-patches.sh --tip >/dev/null 2>&1); then
    echo 'check-patches ignored a failed first patch' >&2
    exit 1
fi

plugin_upstream="$TMP/plugin-upstream"
git init -q "$plugin_upstream"
git -C "$plugin_upstream" config user.email test@example.invalid
git -C "$plugin_upstream" config user.name test
cat > "$plugin_upstream/Makefile.am" <<'EOF'
# fake plugin
# fake plugin
EXTRA_DIST = README COPYING

plugindir = $(libdir)/ntfs-3g

FUSE_CFLAGS = $(FUSE_MODULE_CFLAGS) -DUSE_DOTNET
FUSE_LIBS   = $(FUSE_MODULE_LIBS)

plugin_LTLIBRARIES = ntfs-plugin-80000013.la

ntfs_plugin_80000013_la_SOURCES =	\
	src/dedup.c \
	src/dotnet.c

ntfs_plugin_80000013_la_LDFLAGS  = -module -shared -avoid-version -no-undefined
ntfs_plugin_80000013_la_CPPFLAGS = -D_FILE_OFFSET_BITS=64
EOF
mkdir -p "$plugin_upstream/src"
{
    for _ in {1..61}; do printf '\n'; done
    cat <<'EOF'
 * request a specific FUSE API version.  (It's required on FreeBSD, and it's
 * probably a good idea to request the same version used by NTFS-3G anyway.)
 */
#define FUSE_USE_VERSION 26
#include <fuse.h>

#ifdef HAVE_STRING_H
EOF
} > "$plugin_upstream/src/dedup.c"
chmod +x "$plugin_upstream/Makefile.am" "$plugin_upstream/src/dedup.c"
git -C "$plugin_upstream" add .
git -C "$plugin_upstream" commit -qm base
plugin_commit=$(git -C "$plugin_upstream" rev-parse HEAD)
lock_replace_line dedup-plugin 1.0 "$plugin_commit" patches/ntfs-3g-dedup-plugin-fuse3.patch deadbeef "$plugin_upstream#master"
plugin_work="$TMP/plugin"
patch_prepare_tree dedup-plugin "$plugin_work/source" locked
patch_apply_locked dedup-plugin "$plugin_work/source"
grep -qF "FUSE_CFLAGS = \$(FUSE_MODULE_CFLAGS)" "$plugin_work/source/Makefile.am"
grep -qF '#define FUSE_USE_VERSION 30' "$plugin_work/source/src/dedup.c"

echo 'patch selection tests passed'
