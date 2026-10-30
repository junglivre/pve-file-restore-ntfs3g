#!/usr/bin/env bash
# Watch upstream for new releases and prepare one reviewable bump PR per run.
#
# Default mode is read-only. PUSH=1 uses BOT_TOKEN to update one auto/<date>
# branch, open one PR, and enable auto-merge. SIMULATE_FROM accepts a comma-
# separated list such as "file-restore=4.2.8-2,restore-image=1.0.1"; it creates
# a clearly labelled draft PR and never enables auto-merge.
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
KEEPALIVE=${KEEPALIVE:-0}
PACKAGES_URL='http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz'
DEDUP_REPO=$(lock_source_url dedup-plugin)
RUN_DATE=${RUN_DATE:-$(date -u +%F)}
BRANCH="auto/$RUN_DATE"
if [ -n "$SIMULATE_FROM" ]; then
    BRANCH="auto/sim-${RUN_DATE}-${RANDOM}"
fi
declare -a UPDATES=()
declare -A SIMULATED=()
ORIGINAL_LOCK=$(mktemp)
ORIGINAL_CHANGELOG=$(mktemp)
cp upstream.lock "$ORIGINAL_LOCK"
cp CHANGELOG.md "$ORIGINAL_CHANGELOG"
trap 'rm -f "$ORIGINAL_LOCK" "$ORIGINAL_CHANGELOG"' EXIT


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

ensure_label() {
    local label=$1
    gh label create "$label" --force >/dev/null 2>&1 || true
}

open_bump_pr() {
    local result
    result=$(gh pr list --state open --label upstream-bump \
        --json number,headRefName \
        --jq '.[] | select(.headRefName | startswith("auto/")) | .number') || return 1
    printf '%s\n' "$result" | awk 'NF { print; exit }'
}

open_issue() {
    local title=$1 body=$2 number issue_list
    log "ISSUE: $title"
    if [ "$PUSH" != 1 ] || [ "$DRY_RUN" = 1 ] || [ -n "$SIMULATE_FROM" ]; then
        return 0
    fi
    ensure_label upstream-watch
    issue_list=$(gh issue list --state open --search "in:title $title" --json number,title \
        | jq -r --arg title "$title" '.[] | select(.title == $title) | .number') || return 1
    number=$(printf '%s\n' "$issue_list" | awk 'NF { print; exit }')
    if [ -n "$number" ]; then
        gh issue comment "$number" --body "$body" || return 1
    else
        gh issue create --title "$title" --body "$body" --label upstream-watch ||
            gh issue create --title "$title" --body "$body" || return 1
    fi
}

keepalive() {
    local last now age_days push_output
    last=$(git log -1 --format=%ct) || return 1
    now=$(date +%s)
    age_days=$(( (now - last) / 86400 ))
    log "last commit is $age_days days old"
    if [ "$age_days" -le 45 ]; then
        log 'keepalive: nothing to push'
        return 0
    fi

    [ "$PUSH" = 1 ] || {
        echo 'keepalive requires PUSH=1 when a status commit is needed' >&2
        return 1
    }
    [ -n "${GH_TOKEN:-}" ] || {
        echo 'BOT_TOKEN is required when keepalive has something to push' >&2
        return 1
    }
    git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY:-origin}.git" || return 1
    mkdir -p status || return 1
    date -u +%Y-%m-%dT%H:%M:%SZ > status/last-check || return 1
    git config user.name "github-actions[bot]" || return 1
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com" || return 1
    git add status/last-check || return 1
    git commit -m 'status: keep upstream-watch schedule alive' || return 1
    if ! push_output=$(git push 2>&1); then
        open_issue 'upstream-watch keepalive push refused' \
            "$(printf 'The keepalive push was refused. Reason:\n\n%s' "$push_output")" || return 1
        printf '%s\n' "$push_output" >&2
        return 1
    fi
    log 'keepalive: status pushed'
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
    lock_update "$component" "$version" "$commit" "$patches" "$source" || return 1
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

    local current_upstream
    current_upstream=$(upstream_version_of "$component") || return 1
    if ! dpkg --compare-versions "$new_upstream" gt "$current_upstream"; then
        log "$component: refusing target $new_upstream; current lock is $current_upstream"
        return 0
    fi

    local commit resolve_error
    local resolve_output resolve_reason
    resolve_output=$(mktemp)
    resolve_reason=$(mktemp)
    if ! scripts/resolve-upstream.sh "$component" "$new_upstream" >"$resolve_output" 2>"$resolve_reason"; then
        resolve_error=$(cat "$resolve_reason") || return 1
        rm -f "$resolve_output" "$resolve_reason" || return 1
        open_issue "upstream $new_upstream: release commit not found" \
            "$(printf 'The release commit lookup failed for %s %s. Reason:\n\n%s' \
                "$component" "$new_upstream" "$resolve_error")" || return 1
        return 0
    fi
    commit=$(cat "$resolve_output") || return 1
    rm -f "$resolve_output" "$resolve_reason" || return 1

    local wt prepare_error prepare_output prepare_reason
    wt=$(mktemp -d) || return 1
    prepare_output=$(mktemp) || { rm -rf "$wt"; return 1; }
    prepare_reason=$(mktemp) || {
        rm -rf "$wt" "$prepare_output"
        return 1
    }
    if ! patch_prepare_tree "$component" "$wt/src" "$commit" \
        >"$prepare_output" 2>"$prepare_reason"; then
        prepare_error=$(cat "$prepare_reason") || return 1
        rm -rf "$wt" "$prepare_output" "$prepare_reason" || return 1
        open_issue "upstream $new_upstream: source tree unavailable" \
            "$(printf 'The upstream tree could not be prepared for %s %s (%s). Reason:\n\n%s' \
                "$component" "$new_upstream" "$commit" "$prepare_error")" || return 1
        return 0
    fi
    rm -f "$prepare_output" "$prepare_reason" || return 1

    local disk_source disk_error
    if [ -n "$disk_check" ]; then
        if ! disk_source=$(cat "$wt/src/$disk_check" 2>&1); then
            disk_error=$disk_source
            rm -rf "$wt" || return 1
            open_issue "upstream $new_upstream: source tree missing fallback check" \
                "$(printf 'The prepared %s tree does not contain %s. Reason:\n\n%s' \
                    "$component" "$disk_check" "$disk_error")" || return 1
            return 0
        fi
        if grep -qF 'ntfs-3g' <<<"$disk_source"; then
            rm -rf "$wt" || return 1
            open_issue 'upstream incorporated the ntfs-3g fallback' \
                "Commit $commit ($new_upstream) already mentions ntfs-3g in $disk_check. Human review is required; no bump was proposed." || return 1
            return 0
        fi
    fi

    local selected patch_error patch_output patch_reason
    patch_output=$(mktemp)
    patch_reason=$(mktemp)
    if ! patch_select_paths_in_tree "$component" "$wt/src" "$commit" \
        >"$patch_output" 2>"$patch_reason"; then
        patch_error=$(cat "$patch_reason") || return 1
        rm -rf "$wt" || return 1
        rm -f "$patch_output" "$patch_reason" || return 1
        open_issue "upstream $new_upstream: patch does not apply" \
            "$(printf 'No current or staged next patch selection applies on %s %s (%s). Reason:\n\n%s' \
                "$component" "$new_upstream" "$commit" "$patch_error")" || return 1
        return 0
    fi
    selected=$(cat "$patch_output") || return 1
    rm -rf "$wt" || return 1
    rm -f "$patch_output" "$patch_reason" || return 1

    local previous version patches source
    previous=$(lock_field "$component" version) || return 1
    version="${new_upstream}+ntfs3g1"
    patches=$selected
    source=$(lock_field "$component" source) || return 1
    write_lock_line "$component" "$version" "$commit" "$patches" "$source" || return 1
    write_changelog_section "$component" "$version" "$previous" "$commit" \
        "Upstream bump; selected patch set: $patches." || return 1
    UPDATES+=("$component $version")
    log "$component: queued $version ($commit)"
}

queue_dedup_bump() {
    local head current tmp date short version patches source previous
    local restore_version restore_upstream restore_rev restore_commit restore_patches restore_source next
    local ls_remote_error ls_remote_output ls_remote_reason clone_error patch_error
    ls_remote_output=$(mktemp)
    ls_remote_reason=$(mktemp)
    if ! git ls-remote "$DEDUP_REPO" "$(lock_source_ref dedup-plugin)" >"$ls_remote_output" 2>"$ls_remote_reason"; then
        ls_remote_error=$(cat "$ls_remote_reason") || return 1
        rm -f "$ls_remote_output" "$ls_remote_reason" || return 1
        open_issue 'dedup-plugin: cannot resolve upstream ref' \
            "$(printf 'The dedup-plugin ref lookup failed. Reason:\n\n%s' \
                "$ls_remote_error")" || return 1
        return 0
    fi
    head=$(awk 'NF { print $1; exit }' "$ls_remote_output") || return 1
    rm -f "$ls_remote_output" "$ls_remote_reason" || return 1
    [ -n "$head" ] || {
        open_issue 'dedup-plugin: cannot resolve upstream ref' \
            'The dedup-plugin ref lookup returned no commit.' || return 1
        return 0
    }
    current=$(lock_field dedup-plugin commit)
    if [ "$head" = "$current" ]; then
        log "dedup-plugin: up to date ($current)"
        return 0
    fi

    tmp=$(mktemp -d)
    if ! clone_error=$(patch_clone dedup-plugin "$tmp/src" "$head" 2>&1); then
        rm -rf "$tmp"
        open_issue "dedup-plugin: pinned commit $current no longer fetchable" \
            "$(printf 'The pinned commit is not fetchable. Reason:\n\n%s' \
                "$clone_error")" || return 1
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
            "main ($head) neither contains nor is contained in pinned commit $current. Manual review needed." || return 1
        return 0
    fi
    date=$(git -C "$tmp/src" log -1 --format='%cs' | tr -d -)
    rm -rf "$tmp"
    if ! patch_error=$(patch_select_paths dedup-plugin "$head" 2>&1); then
        open_issue "upstream dedup-plugin ${head:0:7}: patch does not apply" \
            "$(printf 'No current or staged next patch selection applies on %s. Reason:\n\n%s' \
                "$head" "$patch_error")" || return 1
        return 0
    fi
    patches=$patch_error

    short=${head:0:7}
    version="0+git${date}.${short}-1"
    previous=$(lock_field dedup-plugin version) || return 1
    source=$(lock_field dedup-plugin source) || return 1
    write_lock_line dedup-plugin "$version" "$head" "$patches" "$source" || return 1

    # A changed embedded plugin changes the restore image even when its
    # upstream source did not move. Bump its patch revision in the same PR.
    write_changelog_section dedup-plugin "$version" "$previous" "$head" \
        "Upstream source bump; selected patch set: $patches." || return 1
    UPDATES+=("dedup-plugin $version")
    restore_version=$(lock_field restore-image version) || return 1
    restore_upstream=${restore_version%%+ntfs3g*}
    restore_rev=${restore_version##*ntfs3g}
    next=$(( restore_rev + 1 ))
    restore_commit=$(lock_field restore-image commit) || return 1
    restore_patches=$(lock_field restore-image patches) || return 1
    restore_source=$(lock_field restore-image source) || return 1
    write_lock_line restore-image "${restore_upstream}+ntfs3g${next}" "$restore_commit" \
        "$restore_patches" "$restore_source" || return 1
    write_changelog_section restore-image "${restore_upstream}+ntfs3g${next}" \
        "$restore_version" "$restore_commit" \
        "Rebuilt because the embedded dedup-plugin changed." || return 1
    UPDATES+=("restore-image ${restore_upstream}+ntfs3g${next} (embedded dedup plugin)")
    log "dedup-plugin: queued $version ($head)"
}

write_changelog_section() {
    local component=$1 version=$2 previous=$3 commit=$4 description=$5
    python3 - "$component" "$version" "$previous" "$commit" "$description" <<'PY'
import sys
from pathlib import Path

component, version, previous, commit, description = sys.argv[1:]
path = Path('CHANGELOG.md')
text = path.read_text(encoding='utf-8')
heading = f'## {component}/{version}'
if heading in text.splitlines():
    raise SystemExit(0)
marker = '## Unreleased\n'
if marker not in text:
    raise SystemExit('CHANGELOG.md has no Unreleased section')
section = (
    f'{heading}\n\n'
    f'- {description} Previous package version: `{previous}`; '
    f'upstream commit: `{commit}`.\n\n'
)
path.write_text(text.replace(marker, marker + '\n' + section, 1), encoding='utf-8')
PY
}

publish_updates() {
    [ "${#UPDATES[@]}" -gt 0 ] || { log 'no updates'; return 0; }
    log "queued updates: ${UPDATES[*]}"
    [ "$PUSH" = 1 ] || return 0

    git checkout -B "$BRANCH" || return 1
    git add upstream.lock CHANGELOG.md || return 1
    git commit -m "upstream: update pinned components" || return 1
    local push_error
    if ! push_error=$(git push --force-with-lease origin "$BRANCH" 2>&1); then
        open_issue 'upstream-watch branch push refused' \
            "$(printf 'The bump branch push was refused. Reason:\n\n%s' \
                "$push_error")" || return 1
        printf '%s\n' "$push_error" >&2
        return 1
    fi

    local title="upstream: update ${UPDATES[*]}" pr body label
    body=$(printf 'Automatic upstream check queued:\n\n%s\n\n%s' \
        "$(printf -- '- %s\n' "${UPDATES[@]}")" \
        'Patches passed git apply --check. Review CI before merging.')
    if [ -n "$SIMULATE_FROM" ]; then
        label=simulation
        title="[simulation] $title"
        body+=$'\n\nSimulation: this draft PR is based on the current lock, will not auto-merge, and will not release.'
    else
        label=upstream-bump
    fi
    ensure_label "$label"
    pr=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number') || return 1
    if [ -z "$pr" ]; then
        if [ -n "$SIMULATE_FROM" ]; then
            pr=$(gh pr create --base master --head "$BRANCH" --draft --label "$label" \
                --title "$title" --body "$body") || return 1
        else
            pr=$(gh pr create --base master --head "$BRANCH" --label "$label" \
                --title "$title" --body "$body") || return 1
        fi
    else
        gh pr edit "$pr" --title "$title" --body "$body" --add-label "$label" || return 1
    fi
    if [ -z "$SIMULATE_FROM" ]; then
        local merge_error
        if ! merge_error=$(gh pr merge "$pr" --auto --merge 2>&1); then
            open_issue "upstream update PR $pr could not enable auto-merge" \
                "$(printf 'Auto-merge failed for %s. Reason:\n\n%s\n\nThe review PR remains open.' \
                    "$pr" "$merge_error")" || return 1
        fi
    fi
}

if [ "$KEEPALIVE" = 1 ]; then
    keepalive
    exit $?
fi

if [ "$PUSH" = 1 ] && [ "$DRY_RUN" != 1 ] && [ -z "$SIMULATE_FROM" ]; then
    ensure_label upstream-bump
    existing_pr=$(open_bump_pr) || {
        echo 'could not inspect open upstream-bump PRs' >&2
        exit 1
    }
    if [ -n "$existing_pr" ]; then
        log "reusing open upstream bump PR #$existing_pr; no new PR will be created"
        exit 0
    fi
fi

if [ -n "$SIMULATE_FROM" ]; then
    for component in file-restore restore-image; do
        if [ -n "${SIMULATED[$component]:-}" ]; then
            queue_component_bump "$component" "${SIMULATED[$component]}"
        fi
    done
else
    if ! tip_result=$(scripts/check-patches.sh --tip 2>&1); then
        open_issue 'upstream tip breaks patch' "$tip_result" || exit 1
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
    cp "$ORIGINAL_CHANGELOG" CHANGELOG.md
fi
