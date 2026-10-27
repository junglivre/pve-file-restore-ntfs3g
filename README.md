# Proxmox VE File Restore: NTFS-3G fallback

Reliable, read-only Proxmox File Restore access to NTFS volumes that the
in-kernel `ntfs3` driver cannot handle — including Windows Server Data
Deduplication volumes (reparse point `0x80000013`, format `0x0103`), via an
`ntfs-3g` plugin.

Portuguese documentation: [README.pt-BR.md](README.pt-BR.md).

> [!WARNING]
> Unofficial custom build. It changes the Proxmox File Restore packages, not
> the running host kernel. Test in your environment before production. The
> dedup plugin is a third-party GPL-2.0-only component, not a
> Proxmox-supported feature.

## What changes

1. `proxmox-backup-file-restore` falls back to `ntfs-3g -o ro` after all
   in-kernel mounts fail, and **remounts with `ntfs-3g` whenever `ntfs3`
   mounts a deduplicated volume** (detected by
   `System Volume Information/Dedup`): `ntfs3` cannot read dedup reparse
   points, so deduplicated files would otherwise be served with wrong
   content. Volumes without dedup stay on the faster `ntfs3`.
2. `proxmox-backup-restore-image` enables FUSE in the restore kernel and
   bundles `ntfs-3g`, `libfuse3` and the `ntfs-plugin-80000013.so` dedup
   plugin in the File Restore initramfs.
3. The `pve-file-restore-ntfs3g` metapackage depends on the virtual packages
   `proxmox-backup-file-restore-ntfs3g` and
   `proxmox-backup-restore-image-ntfs3g`, which only the patched builds
   provide — an official package can never satisfy it.

All NTFS access happens read-only, inside the restore microVM; the host
kernel and the backups are never touched.

## Install

Releases are published on GitHub: pre-release = `testing`, release =
`stable` (see [docs/releases.md](docs/releases.md)).

- **Cluster / standalone:** see [docs/standalone.md](docs/standalone.md) —
  one command installs on every node:

  ```bash
  ./scripts/cluster-install.sh --hold
  ```

  The `--hold` matters: without a repository or pin, an `apt upgrade`
  replaces the patched packages with the official ones.
- **MasterMind clients:** the packages are also published in the public
  MasterMind APT repository (`https://apt.mastermindti.cloud/debian`), which
  mirrors these releases — install from there, not with the script above.

## Verify

```bash
pve-file-restore-ntfs3g-check          # human-readable, ✔/✘
pve-file-restore-ntfs3g-check --json   # machine-readable
```

## Versioning

Packages are versioned `<exact upstream version>+ntfs3g<N>` and always built
from the upstream release commit (`bump version to <version>`, recorded in
[`upstream.lock`](upstream.lock)) — never from a `master` tip. Debian
ordering: `4.2.8-1 < 4.2.8-1+ntfs3g1 < 4.2.8-2`. See
[CHANGELOG.md](CHANGELOG.md).

## Roll back to the official packages

```bash
apt-mark unhold proxmox-backup-file-restore proxmox-backup-restore-image
apt-get install --allow-downgrades \
  proxmox-backup-file-restore=<official version> \
  proxmox-backup-restore-image=<official version>
```

## Build it yourself

Requirements: Docker, internet, ~35 GB of free disk and several CPU-hours
for the restore-image component (custom kernel + ZFS tools).

```bash
./scripts/build.sh --component all        # or: file-restore | restore-image |
                                          #     dedup-plugin | meta
```

Packages and `SHA256SUMS` land in `dist/`. The build pins everything through
`upstream.lock` (exact commits + patch hashes), uses a digest-pinned
`debian:13` container, and is exactly what CI runs
([docs/automation.md](docs/automation.md)).

## Automation

A daily GitHub Actions watch notices new Proxmox versions, checks that the
patches still apply and opens a bump PR; merging publishes a pre-release
automatically. Promotion to `stable` is manual and approval-gated. Details:
[docs/automation.md](docs/automation.md).

## Upstream and licensing

- Fallback follows the upstream patch series:
  [pbs-devel](https://lore.proxmox.com/pbs-devel/20260514152510.2273112-1-c.ebner@proxmox.com/T/);
  original issue: [Bugzilla #7544](https://bugzilla.proxmox.com/show_bug.cgi?id=7544).
- Dedup plugin: [smx-smx/ntfs-3g-dedup-plugin](https://github.com/smx-smx/ntfs-3g-dedup-plugin),
  GPL-2.0-only, with a FUSE 3 patch.

See [LICENSES.md](LICENSES.md). Proxmox and Debian packages retain their
upstream licenses. No endorsement by Proxmox Server Solutions GmbH, Tuxera
or the plugin author is claimed.
