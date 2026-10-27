# Automation (GitHub Actions)

All workflows run on GitHub-hosted `ubuntu-24.04` runners (free for public
repositories: 4 vCPU, 16 GB RAM, 14 GB SSD, 6 h per job). No self-hosted
runner: on a public repository it would expose the machine to third-party
PRs. No MasterMind tokens exist in this repository.

## One-time setup (repository owner)

1. **`BOT_TOKEN` secret** (Actions): a fine-grained PAT or GitHub App token
   restricted to this repository, with `contents`, `pull-requests` and
   `issues` write. Used by `upstream-watch.yml` to open bump PRs — PRs
   created by `GITHUB_TOKEN` would not trigger CI.
2. **`production` environment** (Settings → Environments): add yourself as a
   required reviewer. `promote.yml` runs in this environment, so promotion to
   stable always waits for explicit approval.
3. Enable **auto-merge** in the repository settings (used for
   `upstream-bump` PRs once checks are green).

## Workflows

### `upstream-watch.yml` — daily (`17 4 * * *`) + manual

`scripts/upstream-watch.sh` compares `upstream.lock` with:

- the `Packages.gz` of `pve-no-subscription` (trixie) for
  `proxmox-backup-file-restore` and `proxmox-backup-restore-image`;
- the tip of `main` of `smx-smx/ntfs-3g-dedup-plugin`.

On a new version it: resolves the release commit
(`scripts/resolve-upstream.sh`), checks the patches still apply, updates
`upstream.lock` on a branch `auto/<component>-<version>` and opens a PR
labelled `upstream-bump` (auto-merge enabled).

Human-review cases (issue instead of a PR):

- the release commit is not found;
- a patch no longer applies;
- `disk.rs` already mentions `ntfs-3g` — upstream incorporated the fallback,
  and our daemon patch shrinks to the dedup detection (see
  [Bugzilla #7544](https://bugzilla.proxmox.com/show_bug.cgi?id=7544) and the
  pbs-devel fallback series).

Scheduled workflows are disabled after 60 days of repository inactivity, so
the workflow commits a timestamp to `status/last-check` whenever the last
commit is older than 45 days.

### `build.yml` — PRs, pushes to master, `workflow_call`

Builds only what changed in `upstream.lock`, `patches/` or `packaging/`:

- `build-file-restore` — Rust workspace of `proxmox-backup` in the
  digest-pinned `debian:13` container; cargo cache keyed on the lock +
  patch hash.
- `build-restore-image` — the heavy one (kernel, ZFS, initramfs; ~35 GB,
  hours). Frees runner toolchains (`dotnet`, `android`, `ghc`,
  `hostedtoolcache`), puts `WORK_DIR` and the Docker `data-root` on `/mnt`,
  logs `df -h` before and after. If it ever stops fitting: (1) split the ZFS
  tools build into its own job passing an artifact, (2) a paid larger runner
  for this job only, (3) local `scripts/build.sh` + manual upload.
- `build-dedup-plugin`, `build-meta` — light.
- `test` — static checks (`strings` on the daemon, `lsinitramfs` contents,
  `Provides:` present), metapackage dependency test (must fail with official
  packages, must succeed with ours), the dedup fixture test (skipped with a
  warning while `tests/fixtures/ntfs-dedup.img.zst` is absent — see
  `tests/README.md`), and a QEMU boot smoke test of the restore kernel +
  initramfs (fails on kernel panic; requires the daemon to appear in the
  boot log).

The full end-to-end test (`proxmox-file-restore` against a real PBS) stays
out of CI for now; it runs on the lab cluster before promotion.

### `release.yml` — push to master touching `upstream.lock`

Calls `build.yml`, then creates the tags `<component>/<version>` and
pre-releases with the `.deb`, `SHA256SUMS`, build log, upstream commit and
the `CHANGELOG.md` section (see `docs/releases.md`). Opens an issue
announcing the pre-release with the promote link.

### `promote.yml` — manual, approval-gated

`workflow_dispatch` with a tag, in the `production` environment. Verifies
the published `SHA256SUMS` against the published `.deb`, then
`gh release edit <tag> --prerelease=false`. Only after lab testing.

## Security

- Third-party actions are pinned by commit SHA.
- `permissions:` are minimal per job (`contents: read` by default; `write`
  only in the watcher, release and promote jobs).
- PRs from forks run build+test without secrets (GitHub default).
- Nothing secret is ever committed; no MasterMind infrastructure is
  referenced by the workflows.
