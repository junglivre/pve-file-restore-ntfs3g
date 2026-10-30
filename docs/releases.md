# Release contract

This document is the stable contract between this repository and its release
consumers. It changes only with a corresponding `CHANGELOG.md` entry.

## Tags and channels

- One release per component, tagged exactly `<component>/<version>`:
  - `file-restore/<upstream version>+ntfs3g<N>` — e.g. `file-restore/4.2.8-1+ntfs3g3`
  - `restore-image/<upstream version>+ntfs3g<N>` — e.g. `restore-image/1.0.0+ntfs3g4`
  - `dedup-plugin/0+git<date>.<short sha>-<N>`
  - `meta/<semver>` — e.g. `meta/2.1.1`
- **Pre-release = `testing` channel. Release (not pre-release) = `stable`
  channel.** Releases start as pre-releases and are promoted only after lab
  validation through the approval-gated `promote.yml` workflow.
- A change to any input that shapes a package requires a new Debian version.
  The tag, `.deb` filename, and Debian `Version` field must be identical.
- The component lock is verified before publication and again before
  promotion. Promotion runs in the protected `production` environment.

## Assets

Every release contains exactly two assets:

- one `.deb`, named `<package>_<version>_<architecture>.deb`:
  `amd64` for `proxmox-backup-file-restore`,
  `proxmox-backup-restore-image`, and `ntfs-3g-plugin-dedup`; `all` for
  `pve-file-restore-ntfs3g`;
- `SHA256SUMS`, containing the checksum of that one `.deb` with its exact asset
  file name.
- The API asset list is part of validation: extra assets, GitHub-rewritten
  names such as `~`, and stale `.deb` files are rejected.

Release notes are the component section from `CHANGELOG.md` plus its upstream
commit. They are release metadata, never an attached asset.

## Rules

- A release is never edited or deleted without the repository owner's explicit
  approval. A fix is a new version and a new tag.
- Patched packages expose versioned feature levels (`daemon (= 2)`,
  `image (= 3)`, and `plugin (= 1)`); the meta package depends on the minimum
  daemon and image levels it requires.
- Debian version ordering is guaranteed:
  `4.2.8-1 < 4.2.8-1+ntfs3g1 < 4.2.8-2 < 4.2.9-1`. No epoch is used.

## Node packages vs. extras

PVE nodes need `file-restore`, `restore-image`, and `meta`.
`ntfs-3g-plugin-dedup` is only needed where ntfs-3g reads deduplicated volumes
outside the restore microVM.
