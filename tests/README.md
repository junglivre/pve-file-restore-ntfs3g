# Test fixtures

## `fixtures/ntfs-dedup-2`

The synthetic Windows Server Data Dedup fixture is published as the
`fixtures/ntfs-dedup-2` release in `junglivre/pve-file-restore-ntfs3g`. This is
an auxiliary fixture release, not one of the four Debian component releases;
it has four assets and no `.deb` or `SHA256SUMS` contract:

- `ntfs-dedup.img.zst`, a bare NTFS partition image;
- `ntfs-dedup.img.zst.sha256`, the image checksum;
- `manifest.sha256`, UTF-8/LF entries in the form `<sha256>  <relative path>`;
- `dedup-files.txt`, the nine Dedup reparse-point paths.

The image is not stored in this repository. A local reference copy is kept in
the lab fixture directory. `tests/fixture/run.sh` verifies the image checksum,
requires a successful read-only mount, and checks that without
`ntfs-3g-dedup-plugin` only the nine listed Dedup paths fail, while with it all
eleven entries match. CI runs both modes against the exact plugin package
built or consumed by that run.

## `fixtures/ntfs-dedup-3`

Big deduplicated files, from a Windows Server 2022 volume made by the lab
script `fixture-big.ps1` (deterministic content). Same assets as
`ntfs-dedup-2`, plus `large-files.txt`, the Dedup paths of 100 MiB or more:

- five files of 100 to 104 MiB (1,199 to 1,344 chunks each, three 512-entry
  windows of the plugin's stream map): text that the chunk store keeps
  compressed, one with random blocks (stored uncompressed), one made of two
  other files, an exact copy, and 100 MiB of random data whose chunks fill
  the first chunk-store container and continue in a second one;
- a 24 MiB and a 200 KiB Dedup file, and two non-Dedup files.

The free clusters of the image are zeroed (`$Bitmap`); allocated clusters are
the bytes Windows wrote. With the plugin before
`patches/ntfs-3g-dedup-plugin-large-files.patch` the five large files come
back with a wrong hash and no read error; with it all nine entries match.
`tests/fixture/run.sh` counts a read error (EIO) as a failure of that path
and reports how many large files matched.

## What CI does

Every pull request runs `tests/run-all.sh`, which runs ShellCheck, actionlint,
the lock check and every offline unit-test suite. When a component or proof
input changes, the artifact job verifies the packages, tests the metapackage
against official and patched APT repositories, downloads both fixture releases,
runs them with and without `ntfs-3g-dedup-plugin`, and/or boots the restore image
under QEMU. The boot proof accepts only timeout rc 124, requires a log line
emitted by the restore daemon itself, and uses a vsock handshake when the
runner provides vhost-vsock. The full PBS restore is a lab proof, not CI.
