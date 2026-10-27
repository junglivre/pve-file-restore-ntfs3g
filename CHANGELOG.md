# Changelog

All notable changes to this project are documented here. Each entry lists the
component releases it ships, identified by their tags (`<component>/<version>`).

Stable contracts that other projects consume:

- the `--json` output of `pve-file-restore-ntfs3g-check` (see
  `packaging/pve-file-restore-ntfs3g/pve-file-restore-ntfs3g-check`);
- the release asset layout documented in `docs/releases.md`.

Both only change in a new entry of this file.

## Unreleased

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
  patch is active on the node. `--json` prints the stable machine-readable
  contract:
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
- Release tags are `<component>/<version>`; `~` in Debian versions is
  encoded as `_` in tags (git refs cannot contain `~`), so the dedup-plugin
  release is tagged `dedup-plugin/0_git20260721.885c77b-1`. See
  `docs/releases.md`.
- GitHub Actions: `upstream-watch.yml` watches new Proxmox versions and opens
  a PR per bump; `build.yml` builds and tests changed components;
  `release.yml` publishes pre-releases (channel `testing`);
  `promote.yml` promotes a pre-release to stable with approval.
- `scripts/cluster-install.sh` installs the stable (or `testing`) releases on
  every online node of a cluster, with optional `apt-mark hold`.
- Repository hygiene: prebuilt `.deb` files and `SHA256SUMS` were removed from
  git; binaries live only in GitHub Releases. `RELEASE_NOTES.md` was replaced
  by this changelog.

## v1.0.0-pve9.2.11 (2026-09-12)

- Initial build: `proxmox-backup-file-restore 4.2.5-1+ntfs3g1` with the
  `ntfs-3g` fallback, and `proxmox-backup-restore-image 1.0.0+ntfs3g1` with
  FUSE, `ntfs-3g` and the dedup plugin in the initramfs. Tested by browsing a
  4 TB NTFS partition from a PBS backup through the PVE File Restore API.
