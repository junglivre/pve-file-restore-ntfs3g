# Proxmox VE File Restore: NTFS-3G fallback

Enable reliable, read-only File Restore access to NTFS volumes when the in-kernel `ntfs3` driver cannot mount them. The restore image also includes an `ntfs-3g` plugin for Windows Server Data Deduplication reparse points (`0x80000013`, including format `0x0103`).

Portuguese documentation: [README.pt-BR.md](README.pt-BR.md).

> [!WARNING]
> This is an unofficial, custom build. It changes Proxmox File Restore packages, not the running host kernel. Test it in your environment and keep the supplied rollback packages. The deduplication plugin is a third-party GPL-2 component, not a Proxmox-supported feature.

## Tested target

The included release assets were built and tested on:

| Component | Version |
| --- | --- |
| Proxmox VE Manager | `9.2.11` |
| Debian base | 13 (Trixie), `amd64` |
| `proxmox-backup-file-restore` base | `4.2.5-1` |
| `proxmox-backup-restore-image` base | `1.0.0` |
| Custom package version | `+ntfs3g1` |

The functional test used the PVE File Restore API to browse an NTFS partition of approximately 4 TB from a PBS backup while the source VM remained online.

## What changes

1. `proxmox-backup-file-restore` tries `/usr/bin/ntfs-3g -o ro` after all in-kernel filesystem mount attempts fail.
2. `proxmox-backup-restore-image` enables built-in FUSE and bundles `ntfs-3g`, `libfuse3`, and `libntfs-3g` in the File Restore initramfs.
3. The initramfs bundles `ntfs-plugin-80000013.so` in the path where `ntfs-3g` automatically loads it.

The fallback is intentionally read-only. It does not alter backup contents or guest disks.

## Install the prebuilt release

Download the two `.deb` files and `SHA256SUMS` from the matching GitHub release, verify their checksums, then install them together:

```bash
sha256sum -c SHA256SUMS
apt-get install ./proxmox-backup-file-restore_4.2.5-1+ntfs3g1_amd64.deb \
  ./proxmox-backup-restore-image_1.0.0+ntfs3g1_amd64.deb
```

No host reboot or guest shutdown is required. A new File Restore session uses the updated image.

Before installing, download the original packages for rollback:

```bash
mkdir -p rollback && cd rollback
apt-get download proxmox-backup-file-restore=4.2.5-1 \
  proxmox-backup-restore-image=1.0.0
```

### Verify the installed result

```bash
dpkg-query -W proxmox-backup-file-restore proxmox-backup-restore-image

strings /usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/proxmox-restore-daemon \
  | grep -F 'try FUSE mount using ntfs-3g'

lsinitramfs /usr/lib/x86_64-linux-gnu/proxmox-backup/file-restore/initramfs.img \
  | grep -E 'ntfs-3g|ntfs-plugin-80000013|libfuse3'
```

### Roll back

From the directory containing the original packages:

```bash
apt-get install ./proxmox-backup-file-restore_4.2.5-1_amd64.deb \
  ./proxmox-backup-restore-image_1.0.0_amd64.deb
```

## Build it yourself

The builder uses a disposable Debian 13 Docker container; it does not install build dependencies on the PVE node.

Requirements: Docker, an internet connection, approximately 35 GB of free disk space, and several CPU-hours for the custom restore kernel and ZFS tools.

```bash
git clone https://github.com/junglivre/pve-file-restore-ntfs3g.git
cd pve-file-restore-ntfs3g
./scripts/build.sh
```

Packages and checksums are placed in `dist/`. The builder pins the upstream source commits listed in [`scripts/versions.sh`](scripts/versions.sh) and validates that the resulting initramfs includes all required NTFS/FUSE components.

## Release assets in this repository

`dist/` contains the release built for the tested target. GitHub releases should attach the same two packages and `SHA256SUMS`.

## Upstream and licensing

- The fallback follows the upstream Proxmox patch series: [PBS development list](https://lore.proxmox.com/pbs-devel/20260514152510.2273112-1-c.ebner@proxmox.com/T/).
- The original issue is [Proxmox Bugzilla #7544](https://bugzilla.proxmox.com/show_bug.cgi?id=7544).
- The deduplication plugin source is [smx-smx/ntfs-3g-dedup-plugin](https://github.com/smx-smx/ntfs-3g-dedup-plugin), GPL-2.0-only.

See [LICENSES.md](LICENSES.md) for component attribution. Proxmox and Debian packages retain their respective upstream licenses.

## Maintenance

This build is deliberately version-specific. A future Proxmox package update can replace these custom packages. Rebuild against new base versions, inspect the package diffs, and retest File Restore before deploying an update.
