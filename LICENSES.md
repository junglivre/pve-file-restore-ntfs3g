# Repository and third-party components and licenses

The repository's own build scripts, tests, packaging metadata, and patch
glue are licensed under AGPL-3.0; see [LICENSE](LICENSE). Upstream code and
third-party components retain their original copyright notices and licenses.

| Component | Purpose | Upstream license/source |
| --- | --- | --- |
| This repository | Build scripts, tests, packaging metadata and patch glue | [AGPL-3.0](LICENSE) |
| Proxmox Backup | File Restore daemon patch | [AGPL-3.0](https://git.proxmox.com/?p=proxmox-backup.git) |
| Proxmox Backup Restore Image | Kernel/initramfs patch | [AGPL-3.0](https://git.proxmox.com/?p=proxmox-backup-restore-image.git) |
| ntfs-3g | FUSE NTFS implementation and runtime library | [GPL-2.0](https://github.com/tuxera/ntfs-3g) |
| ntfs-3g-dedup-plugin | Windows Dedup reparse-point reader | [GPL-2.0-only](https://github.com/smx-smx/ntfs-3g-dedup-plugin) |

The three license families used here are AGPL-3.0, GPL-2.0, and
GPL-2.0-only. No claim of endorsement by Proxmox Server Solutions GmbH,
Tuxera, or the `ntfs-3g-dedup-plugin` author is made.
