#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REAL_GIT=$(command -v git)
export REAL_GIT
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'git %s\n' "$*" >> "$FAKE_GIT_LOG"
if [ "${1:-}" = ls-remote ] && [ -n "${FAKE_GIT_LS_REMOTE:-}" ]; then
    printf '%s\t%s\n' "$FAKE_GIT_LS_REMOTE" 'refs/heads/main'
    exit 0
fi
if [ "${1:-}" = push ] && [ "${FAKE_GIT_PUSH_FAILURE:-0}" = 1 ]; then
    echo 'fake push refused: branch protection' >&2
    exit 1
fi
exec "$REAL_GIT" "$@"
EOF

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'curl %s\n' "$*" >> "$FAKE_CURL_LOG"
[ -n "${FAKE_CURL_PAYLOAD:-}" ] || {
    echo 'fake curl: unexpected network access' >&2
    exit 1
}
cat "$FAKE_CURL_PAYLOAD"
EOF

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "$*" >> "$FAKE_GH_LOG"
case "${1:-}:${2:-}" in
    label:create)
        exit 0
        ;;
    pr:list)
        if [[ "$*" == *'--label upstream-bump'* && "$*" == *'headRefName'* ]]; then
            if [ "${FAKE_GH_MODE:-}" = existing ]; then
                printf '42\n'
            fi
        elif [[ "$*" == *'--head'* ]]; then
            :
        fi
        exit 0
        ;;
    pr:create)
        printf '123\n'
        exit 0
        ;;
    pr:edit|pr:merge)
        exit 0
        ;;
    issue:list)
        printf '[]\n'
        exit 0
        ;;
    issue:create)
        args=("$@")
        for ((i = 0; i < ${#args[@]}; i++)); do
            if [ "${args[i]}" = --body ] && [ $((i + 1)) -lt ${#args[@]} ]; then
                printf 'ISSUE_BODY=%s\n' "${args[i + 1]}" >> "$FAKE_GH_LOG"
            fi
        done
        printf '124\n'
        exit 0
        ;;
    issue:comment)
        exit 0
        ;;
    *)
        echo "fake gh: unexpected command: $*" >&2
        exit 1
        ;;
esac
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/curl" "$FAKE_BIN/gh"

make_upstream() {
    local repo=$1
    mkdir -p "$repo"
    "$REAL_GIT" init -q "$repo"
    "$REAL_GIT" -C "$repo" config user.email test@example.invalid
    "$REAL_GIT" -C "$repo" config user.name test
    printf 'old\n' > "$repo/hello"
    mkdir -p "$repo/proxmox-restore-daemon/src/proxmox_restore_daemon"
    printf 'fn disk() { /* ntfs3 only */ }\n' \
        > "$repo/proxmox-restore-daemon/src/proxmox_restore_daemon/disk.rs"
    "$REAL_GIT" -C "$repo" add .
    "$REAL_GIT" -C "$repo" commit -qm 'base'
    printf 'release\n' > "$repo/hello"
    "$REAL_GIT" -C "$repo" commit -qam 'bump version to 4.2.8-2'
    printf '%s\n' "$($REAL_GIT -C "$repo" rev-parse HEAD)"
}

make_fallback_upstream() {
    local repo=$1
    mkdir -p "$repo/proxmox-restore-daemon/src/proxmox_restore_daemon"
    "$REAL_GIT" init -q "$repo"
    "$REAL_GIT" -C "$repo" config user.email test@example.invalid
    "$REAL_GIT" -C "$repo" config user.name test
    printf 'old\n' > "$repo/hello"
    printf 'the upstream ntfs-3g fallback is now native\n' \
        > "$repo/proxmox-restore-daemon/src/proxmox_restore_daemon/disk.rs"
    "$REAL_GIT" -C "$repo" add .
    "$REAL_GIT" -C "$repo" commit -qm 'base'
    printf 'release\n' > "$repo/hello"
    "$REAL_GIT" -C "$repo" commit -qam 'bump version to 4.2.8-2'
    printf '%s\n' "$($REAL_GIT -C "$repo" rev-parse HEAD)"
}

configure_sandbox() {
    local sandbox=$1 upstream=$2 release_commit=$3 remote
    cp -a "$ROOT/." "$sandbox"
    remote="$TMP/remote-$(basename "$sandbox")"
    "$REAL_GIT" init --bare -q "$remote"
    "$REAL_GIT" -C "$sandbox" remote set-url origin "$remote"
    "$REAL_GIT" -C "$sandbox" push -q --force origin master

    cat > "$sandbox/patches/proxmox-backup-ntfs3g-fallback.patch" <<'EOF'
diff --git a/hello b/hello
--- a/hello
+++ b/hello
@@ -1 +1 @@
-release
+patched
EOF
    python3 - "$sandbox/upstream.lock" "$upstream" "$release_commit" <<'PY'
import sys

lock_path, source, commit = sys.argv[1:]
lines = []
with open(lock_path, encoding='utf-8') as stream:
    for line in stream:
        if line.startswith('file-restore '):
            line = (
                f'file-restore   4.2.8-1+ntfs3g6 {commit} '
                f'patches/proxmox-backup-ntfs3g-fallback.patch sha256:0 '
                f'{source}#master\n'
            )
        lines.append(line)
with open(lock_path, 'w', encoding='utf-8') as stream:
    stream.writelines(lines)
PY
}

run_watch() {
    local sandbox=$1 log_name=$2
    shift 2
    (
        cd "$sandbox"
        export FAKE_GIT_LOG="$TMP/$log_name.git"
        export FAKE_CURL_LOG="$TMP/$log_name.curl"
        export FAKE_GH_LOG="$TMP/$log_name.gh"
        export PATH="$FAKE_BIN:$PATH"
        "$@"
    )
}

assert_contains() {
    local needle=$1 file=$2
    grep -qF -- "$needle" "$file" || {
        echo "missing '$needle' in $file" >&2
        cat "$file" >&2
        exit 1
    }
}

assert_not_contains() {
    local needle=$1 file=$2
    [ -f "$file" ] || return 0
    if grep -qF -- "$needle" "$file"; then
        echo "unexpected '$needle' in $file" >&2
        cat "$file" >&2
        exit 1
    fi
}

upstream="$TMP/upstream"
release_commit=$(make_upstream "$upstream")

# An existing labelled auto/* PR is reused before any upstream lookup or push.
reuse="$TMP/reuse"
configure_sandbox "$reuse" "$upstream" "$release_commit"
run_watch "$reuse" reuse \
    env PUSH=1 GH_TOKEN=fake FAKE_GH_MODE=existing RUN_DATE=2026-10-30 \
    scripts/upstream-watch.sh > "$TMP/reuse.out"
assert_contains 'reusing open upstream bump PR #42' "$TMP/reuse.out"
assert_not_contains 'pr create' "$TMP/reuse.gh"
assert_not_contains 'curl ' "$TMP/reuse.curl"

# A simulation is based on the current lock, gets a simulation-only branch and
# label, and never creates an issue.
simulation="$TMP/simulation"
configure_sandbox "$simulation" "$upstream" "$release_commit"
run_watch "$simulation" simulation \
    env PUSH=1 GH_TOKEN=fake SIMULATE_FROM=file-restore=4.2.8-2 \
    RUN_DATE=2026-10-30 scripts/upstream-watch.sh > "$TMP/simulation.out"
assert_contains '--head auto/sim-' "$TMP/simulation.gh"
assert_contains '--label simulation' "$TMP/simulation.gh"
assert_not_contains 'issue ' "$TMP/simulation.gh"
assert_contains '## file-restore/4.2.8-2+ntfs3g1' \
    <($REAL_GIT -C "$simulation" show HEAD:CHANGELOG.md)
assert_contains 'simulation' "$TMP/simulation.gh"

# If upstream already mentions ntfs-3g in disk.rs, human review is required:
# the watcher opens an explanatory issue and leaves the lock untouched.
fallback_upstream="$TMP/fallback-upstream"
fallback_commit=$(make_fallback_upstream "$fallback_upstream")
fallback="$TMP/fallback"
configure_sandbox "$fallback" "$fallback_upstream" "$fallback_commit"
cat > "$fallback/scripts/check-patches.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo 'tip check passed'
EOF
chmod +x "$fallback/scripts/check-patches.sh"
printf 'Package: proxmox-backup-file-restore\nVersion: 4.2.8-2\n\nPackage: proxmox-backup-restore-image\nVersion: 1.0.0\n' \
    | gzip > "$TMP/Fallback-Packages.gz"
fallback_dedup_commit=$(awk '$1 == "dedup-plugin" { print $3 }' "$fallback/upstream.lock")
cp "$fallback/upstream.lock" "$TMP/fallback.lock.before"
run_watch "$fallback" fallback \
    env PUSH=1 GH_TOKEN=fake FAKE_GIT_LS_REMOTE="$fallback_dedup_commit" \
    FAKE_CURL_PAYLOAD="$TMP/Fallback-Packages.gz" scripts/upstream-watch.sh > "$TMP/fallback.out"
cmp -s "$fallback/upstream.lock" "$TMP/fallback.lock.before"
assert_contains 'upstream incorporated the ntfs-3g fallback' "$TMP/fallback.gh"
assert_contains 'ntfs-3g' "$TMP/fallback.gh"
assert_not_contains 'pr create' "$TMP/fallback.gh"

# A target at or below the current upstream version is refused without a PR.
downgrade="$TMP/downgrade"
configure_sandbox "$downgrade" "$upstream" "$release_commit"
run_watch "$downgrade" downgrade \
    env PUSH=1 GH_TOKEN=fake SIMULATE_FROM=file-restore=4.2.8-1 \
    RUN_DATE=2026-10-30 scripts/upstream-watch.sh > "$TMP/downgrade.out"
assert_contains 'refusing target 4.2.8-1' "$TMP/downgrade.out"
assert_not_contains 'pr create' "$TMP/downgrade.gh"
assert_not_contains 'issue ' "$TMP/downgrade.gh"

# Keepalive checks age before requiring BOT_TOKEN, so a fresh tree needs no
# token and performs no push.
keepalive="$TMP/keepalive"
configure_sandbox "$keepalive" "$upstream" "$release_commit"
(
    cd "$keepalive"
    GIT_AUTHOR_DATE="$(date -u)" GIT_COMMITTER_DATE="$(date -u)" \
        "$REAL_GIT" -c user.name=test -c user.email=test@example.invalid \
        commit --allow-empty -qm 'fresh test commit'
)
run_watch "$keepalive" keepalive \
    env PUSH=1 KEEPALIVE=1 scripts/upstream-watch.sh > "$TMP/keepalive.out"
assert_contains 'keepalive: nothing to push' "$TMP/keepalive.out"
assert_not_contains 'BOT_TOKEN is required' "$TMP/keepalive.out"
assert_not_contains 'git push' "$TMP/keepalive.git"

# Failure issue bodies retain the actual reason returned by the failed check.
failure="$TMP/failure"
configure_sandbox "$failure" "$upstream" "$release_commit"
cat > "$failure/scripts/check-patches.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo 'tip check failed: fake reason' >&2
exit 1
EOF
chmod +x "$failure/scripts/check-patches.sh"
printf 'Package: proxmox-backup-file-restore\nVersion: 4.2.8-1\n\nPackage: proxmox-backup-restore-image\nVersion: 1.0.0\n' \
    | gzip > "$TMP/Packages.gz"
dedup_commit=$(awk '$1 == "dedup-plugin" { print $3 }' "$failure/upstream.lock")
run_watch "$failure" failure \
    env PUSH=1 GH_TOKEN=fake FAKE_GIT_LS_REMOTE="$dedup_commit" \
    FAKE_CURL_PAYLOAD="$TMP/Packages.gz" scripts/upstream-watch.sh > "$TMP/failure.out"
assert_contains 'ISSUE_BODY=' "$TMP/failure.gh"
assert_contains 'tip check failed: fake reason' "$TMP/failure.gh"

echo 'upstream-watch tests passed'
