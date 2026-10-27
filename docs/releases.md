# Release contract

This document is the stable contract between this repository and whoever
consumes its releases (e.g. the public MasterMind APT repository, which polls
the releases hourly and republishes them). It only changes together with a
`CHANGELOG.md` entry.

## Tags and channels

- One release per component, tagged `<component>/<version>`:
  - `file-restore/<upstream version>+ntfs3g<N>` — e.g. `file-restore/4.2.8-1+ntfs3g1`
  - `restore-image/<upstream version>+ntfs3g<N>` — e.g. `restore-image/1.0.0+ntfs3g2`
  - `dedup-plugin/0_git<date>.<short sha>-<N>`
  - `meta/<semver>` — e.g. `meta/2.0.0`
- Git refs cannot contain `~`, so tags encode it as `_` (DEP-14 style): the
  Debian version `0~git20260721.885c77b-1` is tagged
  `dedup-plugin/0_git20260721.885c77b-1`. The `.deb` file name keeps the
  original Debian version.
- **Pre-release = `testing` channel. Release (not pre-release) = `stable`
  channel.** Every release is created as a pre-release and promoted to stable
  only after lab testing, with manual approval (`promote.yml`).

## Assets

Every release contains exactly:

- one `.deb`, named `<package>_<version>_amd64.deb` (package names:
  `proxmox-backup-file-restore`, `proxmox-backup-restore-image`,
  `ntfs-3g-plugin-dedup`, `pve-file-restore-ntfs3g`). GitHub sanitizes asset
  file names, so `~` becomes `.` in the **file name** (e.g.
  `ntfs-3g-plugin-dedup_0.git20260721.885c77b-1_amd64.deb`); the package's
  internal Debian version keeps the `~`. The attached `SHA256SUMS` always
  matches the asset file names.
- `SHA256SUMS` covering that `.deb`;
- the build log;
- release notes: the component's `CHANGELOG.md` section and the upstream
  commit hash the package was built from.

## Rules

- A release is **never edited after promotion**. A fix is a new version (and
  a new tag).
- A release that turns out to be broken while still a pre-release is deleted
  and replaced by a new version, never re-tagged.
- Debian version ordering is guaranteed:
  `4.2.8-1 < 4.2.8-1+ntfs3g1 < 4.2.8-2 < 4.2.9-1`. No epoch is ever used.

## Node packages vs. extras

For PVE nodes you need `file-restore`, `restore-image` and `meta`.
`ntfs-3g-plugin-dedup` is only needed where ntfs-3g reads deduplicated
volumes *outside* the restore microVM.
