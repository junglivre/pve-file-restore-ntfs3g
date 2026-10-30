# Changelog

All notable changes are documented here. Component releases use tags of the
form `<component>/<version>`; `docs/releases.md` defines the stable release
and asset contract.

## Unreleased

## file-restore/4.2.8-1+ntfs3g3

- Version bump for the versioned daemon feature level and the fixed project
  maintainer metadata.

## restore-image/1.0.0+ntfs3g4

- Version bump for the versioned restore-image feature level and the fixed
  project maintainer metadata.

## dedup-plugin/0+git20260721.885c77b-2

- Version bump for the versioned dedup-plugin feature level.

## meta/2.1.1

- Requires the minimum daemon and restore-image feature levels as versioned
  virtual package dependencies.

## file-restore/4.2.8-1+ntfs3g2

- Rebuilt on the exact upstream `proxmox-backup` 4.2.8-1 commit (`78f77d5`).
- The daemon remounts a deduplicated NTFS volume with `ntfs-3g` after an
  `ntfs3` mount, because `ntfs3` cannot read Windows Data Dedup reparse points
  (`0x80000013`). If `ntfs-3g` fails after that unmount, its error explicitly
  states that the volume is no longer mounted.
- Debian changelog entries are generated at build time, so the upstream
  changelog remains untouched in the patch.
- The patched source package uses the project maintainer identity and records
  Proxmox as `XSBC-Original-Maintainer`.

## restore-image/1.0.0+ntfs3g3

- Rebuilt on the exact upstream restore-image 1.0.0 commit (`c0b6cd8`).
- The image build explicitly depends on `libfuse3-dev`; the generated image
  includes FUSE, `ntfs-3g`, `libfuse3`, and `ntfs-plugin-80000013.so`.
- Debian changelog and maintainer handling match `file-restore`.

## dedup-plugin/0+git20260721.885c77b-1

- The standalone plugin package version now sorts newer than the prior
  `0~git...` pre-release and installs the FUSE 3 dedup plugin on Debian 13.

## meta/2.1.0

- `pve-file-restore-ntfs3g-check --json` now reports
  `file_restore.dedup_remount`, emits JSON `null` for an absent package, and
  requires its cache to be newer than both installed package lists.
- The metapackage depends on `initramfs-tools-core`; its `.deb` is architecture
  `all`.

### Project

- Releases are tagged by the exact Debian version and contain only one `.deb`
  and `SHA256SUMS`. Release notes are not assets.
- The upstream watcher batches compatible bumps into one `auto/<date>` PR and
  rebuilds restore-image when the embedded dedup plugin changes.
- Cluster installation verifies one isolated checksum manifest per component;
  `--dry-run` performs no remote operation.

## v1.0.0-pve9.2.11 (2026-09-12)

- Initial build: `proxmox-backup-file-restore 4.2.5-1+ntfs3g1` with the
  `ntfs-3g` fallback, and `proxmox-backup-restore-image 1.0.0+ntfs3g1` with
  FUSE, `ntfs-3g` and the dedup plugin in the initramfs. Tested by browsing a
  4 TB NTFS partition from a PBS backup through the PVE File Restore API.
