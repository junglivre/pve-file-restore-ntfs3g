# Standalone installation

For clusters that use this project directly, without an APT repository.

> MasterMind-managed nodes receive these packages from the public MasterMind
> APT repository: `https://apt.mastermindti.cloud/debian`. Do not use this
> standalone path on those nodes.

## Install (cluster)

Run as root on any node of the cluster:

```bash
./scripts/cluster-install.sh --hold
```

This downloads the latest **stable** GitHub releases of
`proxmox-backup-file-restore`, `proxmox-backup-restore-image`, and the
`pve-file-restore-ntfs3g` metapackage, verifies each release's `SHA256SUMS`,
and installs them on every online node (SSH root between cluster nodes).

Useful modes:

- `--check` — read-only table: node → installed versions → patch active/lost;
- `--channel testing` — install pre-releases (lab only);
- `--from-dir DIR` — install verified offline releases laid out as
  `DIR/{file-restore,restore-image,meta}/{package.deb,SHA256SUMS}`;
- `--dry-run` — show the local and remote operations without contacting a
  remote node or writing anything there.

The script is idempotent: run it again after every new release of this
project.

## Why `--hold` matters

There is no APT repository and no pin here, so **a plain `apt upgrade`
replaces the patched packages with the official Proxmox ones** (the official
versions sort higher, e.g. `4.2.8-2 > 4.2.8-1+ntfs3g1`). `apt-mark hold` on
`proxmox-backup-file-restore` and `proxmox-backup-restore-image` is the only
thing preventing that.

The trade-off: the hold also blocks official fixes to these two packages until
you install the next release of this project — which is published shortly
after each Proxmox release (see `docs/automation.md`).

## Verify

On each node:

```bash
pve-file-restore-ntfs3g-check          # human-readable, ✔/✘
pve-file-restore-ntfs3g-check --json   # machine-readable contract
```

Or cluster-wide: `./scripts/cluster-install.sh --check`.

## Roll back to the official packages

```bash
apt-mark unhold proxmox-backup-file-restore proxmox-backup-restore-image
apt purge pve-file-restore-ntfs3g
apt-get install --allow-downgrades \
  proxmox-backup-file-restore=<official version> \
  proxmox-backup-restore-image=<official version>
```

Never downgrade as a way to *restore the patch*: the fix is always a rebuild
on top of the current upstream version.
