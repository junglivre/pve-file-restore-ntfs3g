#!/usr/bin/env bash
# Watch upstream for new releases and prepare one reviewable bump PR per run.
#
# Default mode is read-only. PUSH=1 uses BOT_TOKEN to update only auto/<date>
# branches, open one PR, and enable auto-merge. SIMULATE_FROM accepts a comma-
# separated list such as "file-restore=4.2.8-2,restore-image=1.0.1"; it creates
# a draft PR and never enables auto-merge.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=lib-lock.sh
source scripts/lib-lock.sh

PUSH=${PUSH:-0}
DRY_RUN=${DRY_RUN:-0}
SIMULATE_FROM=${SIMULATE_FROM:-}
PACKAGES_URL='http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz'
DEDUP_REPO='https://github.com/smx-smx/ntfs-3g-dedup-plugin.git'
RUN_DATE=${RUN_DATE:-$(date -u +%F)}
BRANCH="auto/$RUN_DATE"
declare -a UPDATES=()
declare -A SIMULATED=()
ORIGINAL_LOCK=$(mktemp)
cp upstream.lock "$ORIGINAL_LOCK"
trap 'rm -f "$ORIGINAL_LOCK"' EXIT


log() { echo ":: $*"; }

if [ -n "$SIMULATE_FROM" ]; then
    IFS=',' read -ra entries <<<"$SIMULATE_FROM"
    for entry in "${entries[@]}"; do
        key=${entry%%=*}
        value=${entry#*=}
        [ "$key" != "$entry" ] && [ -n "$key" ] && [ -n "$value" ] || {
            echo "SIMULATE_FROM entries must be component=value: $entry" >&2
            exit 2
        }
        SIMULATED["$key"]=$value
    done
fi

open_issue() {
    local title=$1 body=$2 number
    log "ISSUE: $title"
    [ "$PUSH" = 1 ] && [ "$DRY_RUN" != 1 ] || return 0
    number=$(gh issue list --state open --search "in:title $title" --json number,title \
        --jq ".[] | select(.title == \"$title\") | .number" | head -1 || true)
    if [ -n "$number" ]; then
        gh issue comment "$number" --body "$body"
    else
        gh issue create --title "$title" --body "$body" --label upstream-watch \
            || gh issue create --title "$title" --body "$body"
    fi
}

latest_repo_version() {
    local package=$1
    curl -fsSL "$PACKAGES_URL" | zcat | awk -v pkg="$package" '
        $1 == "Package:" { current = $2 }
        $1 == "Version:" && current == pkg { print $2 }
    ' | sort -V | tail -1
}

upstream_version_of() {
    lock_field "$1" version | sed 's/+ntfs3g[0-9]*$//'
}

write_lock_line() {
    local component=$1 version=$2 commit=$3 rev=$4 patch_hash=$5
    python3 - "$component" "$version" "$commit" "$rev" "$patch_hash" <<'EOF'
import re, sys
component, version, commit, rev, patch_hash = sys.argv[1:]
with open('upstream.lock') as f:
    lines = f.readlines()
with open('upstream.lock', 'w') as f:
    for line in lines:
        if re.match(rf'^{re.escape(component)}\s', line):
            f.write(f"{component:<14} {version:<29} {commit:<41} {rev:<8} {patch_hash}\n")
        else:
            f.write(line)
EOF
}

queue_component_bump() {
    local component=$1 new_upstream=$2
    local patch_file repo_url disk_check=''
    case $component in
        file-restore)
            patch_file=patches/proxmox-backup-ntfs3g-fallback.patch
            repo_url='https://git.proxmox.com/git/proxmox-backup.git'
            disk_check=proxmox-restore-daemon/src/proxmox_restore_daemon/disk.rs
            ;;
        restore-image)
            patch_file=patches/proxmox-backup-restore-image-ntfs3g.patch
            repo_url='https://git.proxmox.com/git/proxmox-backup-restore-image.git'
            ;;
        *) echo "unknown component: $component" >&2; return 1 ;;
    esac

    local commit
    if ! commit=$(scripts/resolve-upstream.sh "$component" "$new_upstream"); then
        open_issue "upstream $new_upstream: release commit not found" \
            "\`resolve-upstream.sh $component $new_upstream\` found no unique release commit. Manual review needed."
        return 0
    fi

    local wt
    wt=$(mktemp -d)
    trap 'rm -rf "$wt"' RETURN
    git clone --quiet "$repo_url" "$wt/src"
    git -C "$wt/src" checkout --quiet "$commit"
    if [ -n "$disk_check" ] && git -C "$wt/src" show "$commit:$disk_check" | grep -qF 'ntfs-3g'; then
        open_issue "upstream incorporated the ntfs-3g fallback" \
            "Commit $commit ($new_upstream) already mentions \`ntfs-3g\` in \`$disk_check\`. The daemon patch needs human review."
        return 0
    fi
    local apply_rc=0
    if [ "$component" = restore-image ]; then
        git clone --quiet "$DEDUP_REPO" "$wt/plugin"
        git -C "$wt/plugin" checkout --quiet "$(lock_field dedup-plugin commit)"
        mkdir -p "$wt/src/src/ntfs-3g-dedup-plugin"
        git -C "$wt/plugin" archive --format=tar HEAD | tar -x -C "$wt/src/src/ntfs-3g-dedup-plugin"
        git -C "$wt/src" apply --check --directory=src/ntfs-3g-dedup-plugin \
            "$ROOT_DIR/patches/ntfs-3g-dedup-plugin-fuse3.patch" || apply_rc=1
    fi
    git -C "$wt/src" apply --check "$ROOT_DIR/$patch_file" || apply_rc=1
    if [ "$apply_rc" -ne 0 ]; then
        open_issue "upstream $new_upstream: patch does not apply" \
            "\`git apply --check $patch_file\` fails on $component $new_upstream ($commit). Manual rebase needed."
        return 0
    fi

    local version="${new_upstream}+ntfs3g1" hash
    hash="sha256:$(sha256sum "$patch_file" | awk '{print $1}')"
    write_lock_line "$component" "$version" "$commit" ntfs3g1 "$hash"
    UPDATES+=("$component $version")
    log "$component: queued $version ($commit)"
}

queue_dedup_bump() {
    local head current tmp date short version hash
    head=$(git ls-remote "$DEDUP_REPO" refs/heads/main | awk '{print $1}')
    [ -n "$head" ] || { echo "cannot resolve dedup plugin main" >&2; return 1; }
    current=$(lock_field dedup-plugin commit)
    [ "$head" = "$current" ] && { log "dedup-plugin: up to date ($current)"; return 0; }

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    git clone --quiet "$DEDUP_REPO" "$tmp/src"
    git -C "$tmp/src" checkout --quiet "$head"
    if ! git -C "$tmp/src" fetch --quiet origin "$current"; then
        open_issue "dedup-plugin: pinned commit $current no longer fetchable" \
            "The pinned commit vanished from upstream (force push?). Manual review needed."
        return 0
    fi
    if git -C "$tmp/src" merge-base --is-ancestor "$head" "$current" 2>/dev/null; then
        log "dedup-plugin: main is behind the pin; nothing to do"
        return 0
    fi
    if ! git -C "$tmp/src" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
        open_issue "dedup-plugin: main diverged from pin" \
            "main ($head) neither contains nor is contained in pinned commit $current. Manual review needed."
        return 0
    fi
    if ! git -C "$tmp/src" apply --check "$ROOT_DIR/patches/ntfs-3g-dedup-plugin-fuse3.patch"; then
        open_issue "upstream dedup-plugin ${head:0:7}: patch does not apply" \
            "\`git apply --check patches/ntfs-3g-dedup-plugin-fuse3.patch\` fails on $head. Manual rebase needed."
        return 0
    fi

    date=$(git -C "$tmp/src" log -1 --format='%cs' | tr -d -)
    short=${head:0:7}
    version="0+git${date}.${short}-1"
    hash="sha256:$(sha256sum patches/ntfs-3g-dedup-plugin-fuse3.patch | awk '{print $1}')"
    write_lock_line dedup-plugin "$version" "$head" 1 "$hash"
    UPDATES+=("dedup-plugin $version")

    # A changed embedded plugin changes the restore image even when its
    # upstream source did not move. Bump its patch revision in the same PR.
    local restore_version restore_upstream restore_rev restore_commit restore_hash next
    restore_version=$(lock_field restore-image version)
    restore_upstream=${restore_version%%+ntfs3g*}
    restore_rev=$(lock_field restore-image rev)
    next=$(( ${restore_rev#ntfs3g} + 1 ))
    restore_commit=$(lock_field restore-image commit)
    restore_hash=$(lock_field restore-image patches_sha256)
    write_lock_line restore-image "${restore_upstream}+ntfs3g${next}" "$restore_commit" \
        "ntfs3g${next}" "sha256:$restore_hash"
    UPDATES+=("restore-image ${restore_upstream}+ntfs3g${next} (embedded dedup plugin)")
    log "dedup-plugin: queued $version ($head)"
}

publish_updates() {
    [ "${#UPDATES[@]}" -gt 0 ] || { log 'no updates'; return 0; }
    log "queued updates: ${UPDATES[*]}"
    [ "$PUSH" = 1 ] || return 0

    git checkout -B "$BRANCH"
    git add upstream.lock
    git commit -m "upstream: update pinned components"
    git push --force-with-lease origin "$BRANCH"

    gh label create upstream-bump --force >/dev/null 2>&1 || true
    local title="upstream: update ${UPDATES[*]}" pr body
    body=$(printf 'Automatic upstream check queued:\n\n%s\n\n%s' \
        "$(printf -- '- %s\n' "${UPDATES[@]}")" \
        'Patches passed git apply --check. Review CI before merging.')
    if [ -n "$SIMULATE_FROM" ]; then
        body+=$'\n\nSimulation: this draft PR will not auto-merge or release.'
    fi
    pr=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' || true)
    if [ -z "$pr" ]; then
        if [ -n "$SIMULATE_FROM" ]; then
            pr=$(gh pr create --base master --head "$BRANCH" --draft --label upstream-bump --title "$title" --body "$body")
        else
            pr=$(gh pr create --base master --head "$BRANCH" --label upstream-bump --title "$title" --body "$body")
        fi
    else
        gh pr edit "$pr" --title "$title" --body "$body" --add-label upstream-bump
    fi
    if [ -z "$SIMULATE_FROM" ]; then
        if ! gh pr merge "$pr" --auto --merge; then
            open_issue "upstream update PR $pr could not enable auto-merge" \
                "Auto-merge failed for $pr. Check branch protection and CI; the review PR remains open."
        fi
    fi
}

if [ -n "$SIMULATE_FROM" ]; then
    for component in file-restore restore-image; do
        [ -n "${SIMULATED[$component]:-}" ] && queue_component_bump "$component" "${SIMULATED[$component]}"
    done
else
    declare -A PACKAGE_OF=(
        [file-restore]=proxmox-backup-file-restore
        [restore-image]=proxmox-backup-restore-image
    )
    for component in file-restore restore-image; do
        latest=$(latest_repo_version "${PACKAGE_OF[$component]}")
        current=$(upstream_version_of "$component")
        log "$component: locked $current, repo has $latest"
        if [ -n "$latest" ] && dpkg --compare-versions "$latest" gt "$current"; then
            queue_component_bump "$component" "$latest"
        fi
    done
    queue_dedup_bump
fi

if [ "$DRY_RUN" = 1 ]; then
    log 'DRY_RUN=1: lock changes are not committed or pushed'
elif [ "$PUSH" = 1 ]; then
    publish_updates
else
    log 'PUSH=1 not set: no branch or PR will be created'
fi

if [ "$PUSH" != 1 ] || [ "$DRY_RUN" = 1 ]; then
    cp "$ORIGINAL_LOCK" upstream.lock
fi
