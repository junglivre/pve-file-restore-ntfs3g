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
# shellcheck source=./scripts/lib-lock.sh
source scripts/lib-lock.sh
# shellcheck source=./scripts/lib-patch.sh
source scripts/lib-patch.sh

PUSH=${PUSH:-0}
DRY_RUN=${DRY_RUN:-0}
SIMULATE_FROM=${SIMULATE_FROM:-}
PACKAGES_URL='http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz'
DEDUP_REPO=$(lock_source_url dedup-plugin)
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
        if [ "$key" = "$entry" ] || [ -z "$key" ] || [ -z "$value" ]; then
            echo "SIMULATE_FROM entries must be component=value: $entry" >&2
            exit 2
        fi
        SIMULATED["$key"]=$value
    done
fi

open_issue() {
    local title=$1 body=$2 number
    log "ISSUE: $title"
    if [ "$PUSH" != 1 ] || [ "$DRY_RUN" = 1 ]; then
        return 0
    fi
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
    local component=$1 version=$2 commit=$3 patches=$4 source=$5
    lock_update "$component" "$version" "$commit" "$patches" "$source"
}

queue_component_bump() {
    local component=$1 new_upstream=$2
    local disk_check=''
    case $component in
        file-restore)
            disk_check=proxmox-restore-daemon/src/proxmox_restore_daemon/disk.rs
            ;;
        restore-image) ;;
        *) echo "unknown component: $component" >&2; return 1 ;;
    esac

    local commit
    if ! commit=$(scripts/resolve-upstream.sh "$component" "$new_upstream"); then
        open_issue "upstream $new_upstream: release commit not found" \
            "\`resolve-upstream.sh $component $new_upstream\` found no unique release commit. Manual review needed."
        return 0
    fi

    local wt selected patches source
    wt=$(mktemp -d)
    if ! patch_prepare_tree "$component" "$wt/src" "$commit"; then
        rm -rf "$wt"
        open_issue "upstream $new_upstream: source commit unavailable" \
            "The locked source cannot reach release commit $commit for $component. Manual review needed."
        return 0
    fi
    disk_source=''
    if [ -n "$disk_check" ]; then
        disk_source=$(cat "$wt/src/$disk_check")
    fi
    if [ -n "$disk_source" ] && grep -qF 'ntfs-3g' <<<"$disk_source"; then
        rm -rf "$wt"
        open_issue "upstream incorporated the ntfs-3g fallback" \
            "Commit $commit ($new_upstream) already mentions \`ntfs-3g\` in \`$disk_check\`. The daemon patch needs human review."
        return 0
    fi
    if ! selected=$(patch_select_paths "$component" "$commit"); then
        rm -rf "$wt"
        open_issue "upstream $new_upstream: patch does not apply" \
            "No current or staged next patch selection applies on $component $new_upstream ($commit). Manual rebase needed."
        return 0
    fi
    rm -rf "$wt"

    local version="${new_upstream}+ntfs3g1"
    patches=$selected
    source=$(lock_field "$component" source)
    write_lock_line "$component" "$version" "$commit" "$patches" "$source"
    UPDATES+=("$component $version")
    log "$component: queued $version ($commit)"
}

queue_dedup_bump() {
    local head current tmp date short version patches source
    head=$(git ls-remote "$DEDUP_REPO" "$(lock_source_ref dedup-plugin)" | awk '{print $1}')
    [ -n "$head" ] || { echo "cannot resolve dedup plugin main" >&2; return 1; }
    current=$(lock_field dedup-plugin commit)
    if [ "$head" = "$current" ]; then
        log "dedup-plugin: up to date ($current)"
        return 0
    fi

    tmp=$(mktemp -d)
    if ! patch_clone dedup-plugin "$tmp/src" "$head" >/dev/null; then
        rm -rf "$tmp"
        open_issue "dedup-plugin: pinned commit $current no longer fetchable" \
            "The pinned commit vanished from upstream (force push?). Manual review needed."
        return 0
    fi
    if git -C "$tmp/src" merge-base --is-ancestor "$head" "$current" 2>/dev/null; then
        rm -rf "$tmp"
        log "dedup-plugin: main is behind the pin; nothing to do"
        return 0
    fi
    if ! git -C "$tmp/src" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
        rm -rf "$tmp"
        open_issue "dedup-plugin: main diverged from pin" \
            "main ($head) neither contains nor is contained in pinned commit $current. Manual review needed."
        return 0
    fi
    date=$(git -C "$tmp/src" log -1 --format='%cs' | tr -d -)
    rm -rf "$tmp"
    if ! patches=$(patch_select_paths dedup-plugin "$head"); then
        open_issue "upstream dedup-plugin ${head:0:7}: patch does not apply" \
            "No current or staged next patch selection applies on $head. Manual rebase needed."
        return 0
    fi

    short=${head:0:7}
    version="0+git${date}.${short}-1"
    source=$(lock_field dedup-plugin source)
    write_lock_line dedup-plugin "$version" "$head" "$patches" "$source"
    UPDATES+=("dedup-plugin $version")

    # A changed embedded plugin changes the restore image even when its
    # upstream source did not move. Bump its patch revision in the same PR.
    local restore_version restore_upstream restore_rev restore_commit restore_patches restore_source next
    restore_version=$(lock_field restore-image version)
    restore_upstream=${restore_version%%+ntfs3g*}
    restore_rev=${restore_version##*ntfs3g}
    next=$(( restore_rev + 1 ))
    restore_commit=$(lock_field restore-image commit)
    restore_patches=$(lock_field restore-image patches)
    restore_source=$(lock_field restore-image source)
    write_lock_line restore-image "${restore_upstream}+ntfs3g${next}" "$restore_commit" \
        "$restore_patches" "$restore_source"
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
        if [ -n "${SIMULATED[$component]:-}" ]; then
            queue_component_bump "$component" "${SIMULATED[$component]}"
        fi
    done
else
    if ! tip_result=$(scripts/check-patches.sh --tip 2>&1); then
        open_issue 'upstream tip breaks patch' "$tip_result"
    else
        log "$tip_result"
    fi
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
