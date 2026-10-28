# Automation (GitHub Actions)

All workflows run on GitHub-hosted `ubuntu-24.04` runners. No self-hosted
runner or MasterMind credential is used by this public repository.

## One-time setup (repository owner)

1. Create the **`production` environment** and add the repository owner as a
   required reviewer. `promote.yml` cannot make a stable release without that
   approval.
2. Set the Actions **`BOT_TOKEN` secret** to a fine-grained PAT or GitHub App
   token restricted to this repository, with `contents`, `pull-requests`, and
   `issues` write. The watcher uses it because a PR made with `GITHUB_TOKEN`
   does not trigger CI or keep the scheduled workflow alive.
3. Set Actions repository variables **`DEBFULLNAME`** and **`DEBEMAIL`** to the
   project maintainer identity that must appear in generated Debian changelog
   entries. The build defaults to a non-personal `.invalid` project identity
   only when these variables are absent.
4. Enable auto-merge. Protect `master` with a ruleset that requires the build
   check and disallows direct pushes; exempt only the GitHub App or bot used by
   `BOT_TOKEN` if it needs to update `auto/*` branches.
5. Provide `tests/fixtures/ntfs-dedup.img.zst` and its SHA256 manifest as
   described in `tests/README.md`. Until the synthetic Windows Data Dedup
   fixture exists, its CI gate deliberately fails rather than skipping.

## Workflows

### `upstream-watch.yml` — daily (`17 4 * * *`) + manual

`scripts/upstream-watch.sh` compares `upstream.lock` with the Proxmox trixie
`pve-no-subscription` package index and the tip of
`smx-smx/ntfs-3g-dedup-plugin` `main`. It resolves release commits and runs
`git apply --check` before changing any pin.

All compatible changes from one run are committed to one `auto/<date>` branch
and one `upstream-bump` PR. The watcher force-pushes only that `auto/*` branch.
It updates an existing open issue with the same title instead of creating
duplicates. If GitHub refuses auto-merge, it opens or updates an issue and
leaves the PR for review.

A `workflow_dispatch` run accepts:

- `simulate_from`: comma-separated `component=upstream-version` pairs, for
  example `file-restore=4.2.8-2`; creates a draft simulation PR and never
  enables auto-merge;
- `dry_run`: checks candidates without creating a branch, PR, or issue.

A dedup-plugin pin update also increments the restore-image `ntfs3g` patch
revision because the plugin is embedded in that image.

### `build.yml` — pull requests and reusable calls

Builds only affected components. The restore image is also rebuilt whenever
`dedup-plugin` changes. There is no ineffective cargo cache: the Rust build
runs in its actual container work directory.

The test job runs shell tests for `cluster-install.sh` and
`pve-file-restore-ntfs3g-check`, validates generated Debian changelogs and
maintainer metadata, builds local APT repositories with official and patched
packages to test the metapackage dependency boundary, validates the dedup
fixture, and rejects a QEMU boot that reports a missing restore daemon.

The full restore against a real PBS and a deduplicated NTFS volume is a lab
validation before promotion, not public CI.

### `release.yml` — push to master touching `upstream.lock`

Calls `build.yml`, then creates testing pre-releases tagged exactly
`<component>/<version>`. Each release contains only its one `.deb` and
`SHA256SUMS`; the changelog section and upstream commit are release notes.

### `promote.yml` — manual, approval-gated

A dispatch with a release tag runs in the `production` environment, verifies
published checksums, then clears the pre-release flag. Run it only after lab
validation.

## Security

- Third-party actions are pinned by commit SHA.
- Permissions are scoped per workflow.
- Fork PRs do not receive secrets.
- Release data and logs never contain client information, credentials, or
  MasterMind infrastructure details.
