# Changelog

All notable changes are documented here. Component releases use tags of the
form `<component>/<version>`; `docs/releases.md` defines the stable release
and asset contract.

## Unreleased

## restore-image/1.1.0+ntfs3g1

- Upstream bump; selected patch set: patches/next/proxmox-backup-restore-image-ntfs3g.patch. Previous package version: `1.0.0+ntfs3g11`; upstream commit: `029559ce22feb86afe8e6d5c4767ad5e95b120a5`.


Project-wide changes that ship with the component releases below:

- Component builds write one package and one `SHA256SUMS` to each
  `dist/<component>/` directory; `--component all` still builds the complete
  set.
- `cluster-install.sh` follows PVE 9's per-node SSH known_hosts, holds both
  patched packages with `--hold` (not the metapackage), and its reports
  include redacted last-40-line stdout/stderr tails per node.
- The repository's own code is AGPL-3.0; the upstream `ntfs-3g` code is
  GPL-2.0 and `ntfs-3g-dedup-plugin` remains GPL-2.0-only.

## file-restore/4.2.8-1+ntfs3g9

- Rebuilt on the exact upstream `proxmox-backup` 4.2.8-1 commit (`78f77d5`).
- The daemon falls back to `ntfs-3g` after all in-kernel mounts fail and
  remounts a deduplicated NTFS volume with `ntfs-3g` after an `ntfs3` mount;
  `ntfs3` cannot read Windows Data Deduplication reparse points
  (`0x80000013`).
- The package exposes the versioned daemon feature level and uses the project
  maintainer identity while retaining Proxmox as `XSBC-Original-Maintainer`.

## restore-image/1.0.0+ntfs3g11

- Rebuilt on the exact upstream restore-image 1.0.0 commit (`c0b6cd8`).
- The image build enables FUSE and includes `ntfs-3g`, `libfuse3`, and the
  `ntfs-3g-dedup-plugin` shared object in the File Restore initramfs.
- Embeds the dedup plugin that reads big deduplicated files correctly
  (`dedup-plugin/0+git20260721.885c77b-9`) and exposes restore-image feature
  level 4, so an image with the older plugin can no longer satisfy the
  metapackage.
- The package uses the project maintainer identity.

## dedup-plugin/0+git20260721.885c77b-9

- The standalone `ntfs-3g-dedup-plugin` package is built from `885c77b` with
  the FUSE 3 patch, exposes its versioned feature level (now 2), and declares
  both `ntfs-3g` and its `libntfs-3g` runtime dependency.
- Fixes deduplicated files bigger than about 37 MiB, which came back silently
  truncated or with wrong content (and rc 0 from File Restore): the plugin
  only looked at the first 512 entries of a file's stream map, so a read
  crossing that point returned a short count, which the kernel takes as the
  end of file. The stream map is now read through a window that follows the
  read (`patches/ntfs-3g-dedup-plugin-large-files.patch`).
- Every chunk is checked against the SHA-512 digest recorded in its stream
  map entry, and the stream map itself is checked; a read that cannot be
  completed and checked fails with EIO instead of returning wrong or short
  data.

## meta/2.1.11

- The metapackage depends on the minimum daemon and restore-image feature
  levels (restore-image level 4: the image with the big-file plugin fix),
  `initramfs-tools-core`, and `cpio`, which the upstream file-restore postinst
  uses when rebuilding the initramfs cache.
- `pve-file-restore-ntfs3g-check` only reports ACTIVE with a level 4 restore
  image.
- `pve-file-restore-ntfs3g-check --json` reports the stable
  `file_restore.dedup_remount` field, emits JSON `null` for an absent package,
  accepts packages put on hold, and requires a cache newer than both installed
  package lists that holds the patched daemon in its appended newc archive.

## Published history

### file-restore/4.2.8-1+ntfs3g1

- Rebuilt exactly on the upstream `proxmox-backup` release commit for 4.2.8-1
  (`78f77d5`). The previous build was based on a commit after the 4.2.5-1
  release, so the package version did not match the code.
- The daemon now remounts deduplicated NTFS volumes with `ntfs-3g` when the
  in-kernel `ntfs3` driver mounts them: `ntfs3` cannot read Windows Server
  Data Deduplication reparse points (`0x80000013`), so deduplicated files
  would otherwise be served with wrong content. Detection: a
  `System Volume Information/Dedup` directory on the mounted volume.
- The `ntfs-3g` fallback after all in-kernel mounts fail is unchanged.
- The package now provides the virtual package
  `proxmox-backup-file-restore-ntfs3g (= ${binary:Version})`.

### restore-image/1.0.0+ntfs3g2

- Rebuilt exactly on the upstream `proxmox-backup-restore-image` release
  commit for 1.0.0 (`c0b6cd8`); the previous build used a commit after 1.0.0.
- Unchanged content: FUSE enabled in the restore kernel, `ntfs-3g`, `libfuse3`
  and the `ntfs-plugin-80000013.so` dedup plugin in the initramfs.
- The package now provides the virtual package
  `proxmox-backup-restore-image-ntfs3g (= ${binary:Version})`.

### meta/2.0.0 (new)

- New metapackage `pve-file-restore-ntfs3g`. It depends on the two virtual
  packages above, so an unpatched official package can never satisfy it.
- Ships `/usr/sbin/pve-file-restore-ntfs3g-check`, which verifies that the
  patch is active on the node. `--json` prints the machine-readable contract:
  `{"ok", "file_restore": {"version", "patched"}, "restore_image":
  {"version", "ntfs3g", "dedup_plugin"}, "initramfs_cache_fresh"}`.

### dedup-plugin/0~git20260721.885c77b-1 (new)

- New standalone package `ntfs-3g-plugin-dedup`, installing
  `ntfs-plugin-80000013.so` into the ntfs-3g plugin directory of Debian 13.
  Built from `smx-smx/ntfs-3g-dedup-plugin` at `885c77b` with the FUSE 3
  patch. GPL-2.0-only, attribution in the package copyright file.

### Project

- `upstream.lock` replaces `scripts/versions.sh` as the single source of
  truth: upstream version, exact release commit, patch revision and patch
  hashes per component. `scripts/resolve-upstream.sh` finds a release commit
  by its `bump version to <version>` message.
- `scripts/build.sh --component <...>` builds a single component or all, in a
  digest-pinned `debian:13` container; the same script runs in CI.
- Release tags are `<component>/<version>`; `~` in Debian versions is encoded
  as `_` in tags (git refs cannot contain `~`), so the dedup-plugin release is
  tagged `dedup-plugin/0_git20260721.885c77b-1`.
- GitHub Actions watch new Proxmox versions, build and test changed
  components, publish testing pre-releases, and promote them to stable only
  with approval.
- `scripts/cluster-install.sh` installs the stable or testing releases on
  every online node of a cluster, with optional `apt-mark hold`.
- Prebuilt `.deb` files and `SHA256SUMS` were removed from git; binaries live
  only in GitHub Releases. `RELEASE_NOTES.md` was replaced by this changelog.

## v1.0.0-pve9.2.11 (2026-09-12)

- Initial build: `proxmox-backup-file-restore 4.2.5-1+ntfs3g1` with the
  `ntfs-3g` fallback, and `proxmox-backup-restore-image 1.0.0+ntfs3g1` with
  FUSE, `ntfs-3g` and the `ntfs-plugin-80000013.so` in the initramfs. Tested
  by browsing a 4 TB NTFS partition from a PBS backup through the PVE File
  Restore API.
