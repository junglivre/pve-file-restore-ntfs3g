# v1.0.0-pve9.2.11

Prebuilt `amd64` packages for Proxmox VE Manager 9.2.11:

- `proxmox-backup-file-restore_4.2.5-1+ntfs3g1_amd64.deb`
- `proxmox-backup-restore-image_1.0.0+ntfs3g1_amd64.deb`

This release adds a read-only `ntfs-3g` fallback after failed in-kernel filesystem mounts and bundles FUSE, `ntfs-3g`, and the Windows Server Dedup `0x80000013` plugin in the File Restore image.

The packages were functionally tested by browsing a 4 TB NTFS partition from a PBS backup through the PVE File Restore API, with the source VM online.

Verify assets using `SHA256SUMS` before installation. See `README.md` for installation and rollback instructions.
