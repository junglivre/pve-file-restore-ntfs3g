#!/usr/bin/env bash
# Watch upstream for new releases and prepare a bump PR per component.
#
#   scripts/upstream-watch.sh
#
# Read-only by itself: it prints what it would do. With PUSH=1 it pushes the
# auto/<component>-<version> branch and opens a pull request labelled
# upstream-bump (requires gh authenticated with a token that triggers CI,
# i.e. BOT_TOKEN, not GITHUB_TOKEN).
#
# Failure handling (a missing release commit, a patch that no longer applies,
# or the ntfs-3g fallback appearing upstream) opens a GitHub issue instead of
# a PR.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=lib-lock.sh
source scripts/lib-lock.sh

PUSH=${PUSH:-0}
PACKAGES_URL='http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz'
DEDUP_REPO='https://github.com/smx-smx/ntfs-3g-dedup-plugin.git'

log() { echo ":: $*"; }

open_issue() {
    local title=$1 body=$2
    log "ISSUE: $title"
    if [ "$PUSH" = 1 ]; then
        gh issue create --title "$title" --body "$body" --label upstream-watch \
            || gh issue create --title "$title" --body "$body"
    fi
}

latest_repo_version() {
    # latest_repo_version <package> -> newest version in the pve-no-subscription repo
    local package=$1
    curl -fsSL "$PACKAGES_URL" | zcat | awk -v pkg="$package" '
        $1 == "Package:" { current = $2 }
        $1 == "Version:" && current == pkg { print $2 }
    ' | sort -V | tail -1
}

upstream_version_of() {
    # strip our +ntfs3gN suffix
    lock_field "$1" version | sed 's/+ntfs3g[0-9]*$//'
}

bump_component() {
    # bump_component <component> <new upstream version>
    local component=$1 new_upstream=$2
    local patch_file repo_url disk_check=""
    case $component in
        file-restore)
            patch_file=patches/proxmox-backup-ntfs3g-fallback.patch
            disk_check=proxmox-restore-daemon/src/proxmox_restore_daemon/disk.rs
            ;;
        restore-image)
            patch_file=patches/proxmox-backup-restore-image-ntfs3g.patch
            ;;
        *) echo "bump_component: unknown component $component" >&2; return 1 ;;
    esac

    log "$component: new upstream version $new_upstream"

    local commit
    if ! commit=$(scripts/resolve-upstream.sh "$component" "$new_upstream"); then
        open_issue "upstream $new_upstream: release commit not found" \
            "\`resolve-upstream.sh $component $new_upstream\` found no unique commit \`bump version to $new_upstream\`. Manual review needed."
        return 0
    fi
    log "$component: release commit $commit"

    # If upstream incorporated the ntfs-3g fallback, our daemon patch shrinks
    # to the dedup detection; that is a human review, not an auto-PR.
    if [ -n "$disk_check" ]; then
        case $component in
            file-restore) repo_url='https://git.proxmox.com/git/proxmox-backup.git' ;;
            restore-image) repo_url='https://git.proxmox.com/git/proxmox-backup-restore-image.git' ;;
        esac
        local tmp
        tmp=$(mktemp -d)
        git clone --bare --quiet "$repo_url" "$tmp/repo"
        if git -C "$tmp/repo" show "$commit:$disk_check" | grep -q 'ntfs-3g'; then
            rm -rf "$tmp"
            open_issue "upstream incorporated the ntfs-3g fallback" \
                "Commit $commit ($new_upstream) already mentions \`ntfs-3g\` in \`$disk_check\`. The daemon patch must be reduced to the dedup detection. Manual review needed."
            return 0
        fi
        rm -rf "$tmp"
    fi

    # The patches must still apply on the new release commit.
    local wt
    wt=$(mktemp -d)
    case $component in
        file-restore) repo_url='https://git.proxmox.com/git/proxmox-backup.git' ;;
        restore-image) repo_url='https://git.proxmox.com/git/proxmox-backup-restore-image.git' ;;
    esac
    git clone --quiet "$repo_url" "$wt/src"
    git -C "$wt/src" checkout --quiet "$commit"
    local apply_rc=0
    if [ "$component" = restore-image ]; then
        # restore-image also applies the dedup plugin patch inside src/
        git clone --quiet "$DEDUP_REPO" "$wt/plugin"
        git -C "$wt/plugin" checkout --quiet "$(lock_field dedup-plugin commit)"
        mkdir -p "$wt/src/src/ntfs-3g-dedup-plugin"
        git -C "$wt/plugin" archive --format=tar HEAD \
            | tar -x -C "$wt/src/src/ntfs-3g-dedup-plugin"
        git -C "$wt/src" apply --check --directory=src/ntfs-3g-dedup-plugin \
            "$ROOT_DIR/patches/ntfs-3g-dedup-plugin-fuse3.patch" || apply_rc=1
    fi
    git -C "$wt/src" apply --check "$ROOT_DIR/$patch_file" || apply_rc=1
    rm -rf "$wt"
    if [ "$apply_rc" -ne 0 ]; then
        open_issue "upstream $new_upstream: patch does not apply" \
            "\`git apply --check $patch_file\` fails on $component $new_upstream ($commit). Manual rebase needed."
        return 0
    fi

    # New upstream version resets the patch revision to ntfs3g1 (D6).
    local new_version="${new_upstream}+ntfs3g1"
    local patch_hash
    patch_hash=$(sha256sum "$patch_file" | awk '{print $1}')
    # git refs cannot contain '~' or '+'
    local branch="auto/${component}-${new_version//[~+]/-}"

    log "$component: updating upstream.lock -> $new_version ($commit)"
    python3 - "$component" "$new_version" "$commit" "$patch_hash" <<'EOF'
import re, sys
component, version, commit, patch_hash = sys.argv[1:5]
with open('upstream.lock') as f:
    lines = f.readlines()
with open('upstream.lock', 'w') as f:
    for line in lines:
        if re.match(rf'^{re.escape(component)}\s', line):
            f.write(f"{component:<14} {version:<29} {commit}  ntfs3g1  sha256:{patch_hash}\n")
        else:
            f.write(line)
EOF

    git checkout -b "$branch"
    git add upstream.lock
    git commit -m "upstream: bump $component to $new_version"
    if [ "$PUSH" = 1 ]; then
        git push origin "$branch"
        gh label create upstream-bump --force >/dev/null 2>&1 || true
        gh pr create --base master --head "$branch" --label upstream-bump \
            --title "upstream: bump $component to $new_version" \
            --body "Automatic bump: upstream released $new_upstream (commit $commit). Patches still apply. Patch revision reset to ntfs3g1."
        gh pr merge "$branch" --auto --merge
    else
        log "PUSH=1 not set; branch $branch stays local"
    fi
    git checkout -q master 2>/dev/null || git checkout -q main
}

bump_dedup_plugin() {
    local head
    head=$(git ls-remote "$DEDUP_REPO" refs/heads/main | awk '{print $1}')
    [ -n "$head" ] || { echo "cannot resolve dedup plugin main" >&2; return 1; }
    local current
    current=$(lock_field dedup-plugin commit)
    if [ "$head" = "$current" ]; then
        log "dedup-plugin: up to date ($current)"
        return 0
    fi

    local tmp date short
    tmp=$(mktemp -d)
    git clone --quiet "$DEDUP_REPO" "$tmp/src"
    git -C "$tmp/src" checkout --quiet "$head"
    # Our pin may live outside main's branches (an unmerged fix); fetch it
    # explicitly for the ancestry checks below.
    if ! git -C "$tmp/src" fetch --quiet origin "$current"; then
        rm -rf "$tmp"
        open_issue "dedup-plugin: pinned commit $current no longer fetchable" \
            "The pinned commit vanished from the upstream repository (force push?). Manual review needed."
        return 0
    fi
    # Our pinned commit may be ahead of main (e.g. an unmerged fix). Only
    # bump when main actually has something our pin does not.
    if git -C "$tmp/src" merge-base --is-ancestor "$head" "$current" 2>/dev/null; then
        log "dedup-plugin: main ($head) is behind our pin ($current); nothing to do"
        rm -rf "$tmp"
        return 0
    fi
    if ! git -C "$tmp/src" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
        rm -rf "$tmp"
        open_issue "dedup-plugin: main diverged from our pin" \
            "main ($head) neither contains nor is contained in the pinned commit $current. Manual review needed."
        return 0
    fi
    log "dedup-plugin: main moved $current -> $head"
    date=$(git -C "$tmp/src" log -1 --format='%cs' | tr -d -)
    short=${head:0:7}
    if ! git -C "$tmp/src" apply --check "$ROOT_DIR/patches/ntfs-3g-dedup-plugin-fuse3.patch"; then
        rm -rf "$tmp"
        open_issue "upstream dedup-plugin $short: patch does not apply" \
            "\`git apply --check patches/ntfs-3g-dedup-plugin-fuse3.patch\` fails on smx-smx/ntfs-3g-dedup-plugin@$head. Manual rebase needed."
        return 0
    fi
    rm -rf "$tmp"

    local new_version="0~git${date}.${short}-1"
    local patch_hash
    patch_hash=$(sha256sum patches/ntfs-3g-dedup-plugin-fuse3.patch | awk '{print $1}')
    local branch="auto/dedup-plugin-${new_version//[~+]/-}"

    python3 - "$new_version" "$head" "$patch_hash" <<'EOF'
import re, sys
version, commit, patch_hash = sys.argv[1:4]
with open('upstream.lock') as f:
    lines = f.readlines()
with open('upstream.lock', 'w') as f:
    for line in lines:
        if re.match(r'^dedup-plugin\s', line):
            f.write(f"dedup-plugin   {version:<29} {commit}  1        sha256:{patch_hash}\n")
        else:
            f.write(line)
EOF

    git checkout -b "$branch"
    git add upstream.lock
    git commit -m "upstream: bump dedup-plugin to $new_version"
    if [ "$PUSH" = 1 ]; then
        git push origin "$branch"
        gh label create upstream-bump --force >/dev/null 2>&1 || true
        gh pr create --base master --head "$branch" --label upstream-bump \
            --title "upstream: bump dedup-plugin to $new_version" \
            --body "Automatic bump: smx-smx/ntfs-3g-dedup-plugin main moved to $head. Patch still applies."
        gh pr merge "$branch" --auto --merge
    else
        log "PUSH=1 not set; branch $branch stays local"
    fi
    git checkout -q master 2>/dev/null || git checkout -q main
}

# --- file-restore and restore-image: compare against pve-no-subscription ---
declare -A PACKAGE_OF=(
    [file-restore]=proxmox-backup-file-restore
    [restore-image]=proxmox-backup-restore-image
)
for component in file-restore restore-image; do
    latest=$(latest_repo_version "${PACKAGE_OF[$component]}")
    current=$(upstream_version_of "$component")
    log "$component: locked $current, repo has $latest"
    if [ -n "$latest" ] && dpkg --compare-versions "$latest" gt "$current"; then
        bump_component "$component" "$latest"
    fi
done

bump_dedup_plugin
