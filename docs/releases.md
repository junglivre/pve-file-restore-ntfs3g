# Release contract

This document is the stable contract between this repository and its release
consumers. It changes only with a corresponding `CHANGELOG.md` entry. The
MasterMind APT consumer polls GitHub Releases hourly.

## Tags and channels

- One release per component, tagged exactly `<component>/<version>`:
  - `file-restore/<upstream version>+ntfs3g<N>` — e.g. `file-restore/4.2.8-1+ntfs3g9`
  - `restore-image/<upstream version>+ntfs3g<N>` — e.g. `restore-image/1.0.0+ntfs3g10`
  - `dedup-plugin/0+git<date>.<short sha>-<N>` — current lock: `...-8`
  - `meta/<semver>` — current lock: `meta/2.1.10`
- **Pre-release = `testing` channel. Release (not pre-release) = `stable`
  channel.** Releases start as pre-releases and are promoted only after lab
  validation through the approval-gated `promote.yml` workflow.
- The tag, `.deb` filename, and Debian `Version` are checked independently.
  **Version is read from the `.deb`**, not inferred from a filename or tag.
- A change to any input that shapes a package requires a new Debian version.
  The tag, `.deb` filename, and Debian `Version` field must identify the same
  release. GitHub rewrites `~` in asset names, so a version containing `~` is
  rejected before publication; `+` is kept as is.
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
- The checksum is looked up by the exact `.deb` asset name. It is not enough
  for a checksum file to contain a matching digest under another name.
- `Package`, `Version`, and `Architecture` are read with `dpkg-deb -f` from
  the downloaded `.deb`; they must match the component contract above.

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

## Checker JSON contract

`pve-file-restore-ntfs3g-check --json` emits one JSON object and exits zero
only when `ok` is `true`:

```json
{
  "ok": true,
  "file_restore": {
    "version": "4.2.8-1+ntfs3g9",
    "patched": true,
    "dedup_remount": true
  },
  "restore_image": {
    "version": "1.0.0+ntfs3g10",
    "ntfs3g": true,
    "dedup_plugin": true
  },
  "initramfs_cache_fresh": true
}
```

`version` is a Debian version string or JSON `null` when that package is not
installed. `dedup_remount` is part of the stable contract: it proves that the
daemon contains the deduplicated-volume remount path, separately from the
generic `ntfs-3g` fallback. The checker also verifies the cached initramfs and
the patched daemon in its appended newc archive.

## Node packages vs. extras

PVE nodes need `file-restore`, `restore-image`, and `meta`.
The `ntfs-3g-plugin-dedup` package is only needed where
`ntfs-3g-dedup-plugin` reads deduplicated volumes outside the restore microVM.

## Fixture and legacy releases

`fixtures/ntfs-dedup-2` is a non-package GitHub Release used by CI and the lab.
It intentionally contains four fixture assets — `ntfs-dedup.img.zst`, its
`.sha256` file, `manifest.sha256`, and `dedup-files.txt` — and does not follow
the two-asset Debian release contract above.

The historical `v1.0.0-pve9.2.11` release is a legacy project release, not a
`<component>/<version>` release. It is retained for history and is not selected
by `cluster-install.sh` or the MasterMind APT importer. New releases must use
the component tags and assets documented above.

The 2026-10-27 pre-releases (`file-restore/4.2.8-1+ntfs3g1`,
`restore-image/1.0.0+ntfs3g2`, `meta/2.0.0` and
`dedup-plugin/0_git20260721.885c77b-1`) predate the two-asset contract: they
also carry a build log and `notes.md`, and the plugin one does not carry its
Debian version verbatim. `scripts/lib-release.sh` rejects them; the next
release cycle supersedes them.
