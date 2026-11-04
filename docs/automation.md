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
3. Enable auto-merge. Protect `master` with a ruleset that requires pull
   requests, disallows direct pushes, and requires the status check named
   `checks` (the `checks` job of `build.yml`; the pull request page shows it as
   `build / checks`). Exempt only the GitHub App or bot used by `BOT_TOKEN` if
   it needs to update `auto/*` branches.
4. Publish the synthetic fixtures as the `fixtures/ntfs-dedup-2` and
   `fixtures/ntfs-dedup-3` releases, as described in `tests/README.md`. They
   are fixture releases (four and five assets), not Debian component
   releases.

## Workflows

### `upstream-watch.yml` — daily (`17 4 * * *`) + manual

`scripts/upstream-watch.sh` compares `upstream.lock` with the Proxmox trixie
`pve-no-subscription` package index and the pinned source ref of
`smx-smx/ntfs-3g-dedup-plugin` (currently `refs/pull/1/head`). It resolves
release commits and runs `git apply --check` before changing any pin.

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

Builds only affected components, writing each component to its own
`dist/<component>/` directory with its own `SHA256SUMS`. The restore image is
also rebuilt whenever `dedup-plugin` changes. There is no ineffective cargo
cache: the Rust build runs in its actual container work directory.

The `checks` job runs `tests/run-all.sh` on every pull request. That includes
ShellCheck, actionlint, all offline unit suites, and the lock check against the
PR base. When the change filter marks the run heavy, artifact proofs validate
the Debian packages, build local APT repositories with official and patched
packages to test the metapackage boundary, run the published fixture with and
without `ntfs-3g-dedup-plugin`, and/or run the QEMU boot smoke.

The boot smoke appends the freshly built daemon to the image's newc initramfs,
starts QEMU, requires the daemon's `setup basic system environment...` marker,
and accepts only timeout exit status 124. It rejects panic, setup failure and
missing-daemon logs. If `/dev/vhost-vsock` is available, it also requires an
HTTP status response from the daemon; without it, the smoke explicitly checks
daemon execution only. The complete PBS restore is a lab validation before
promotion, not public CI.

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
