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

## What CI does

Every pull request runs `tests/run-all.sh`, which runs ShellCheck, actionlint,
the lock check and every offline unit-test suite. When a component or proof
input changes, the artifact job verifies the packages, tests the metapackage
against official and patched APT repositories, downloads this fixture release,
runs it with and without `ntfs-3g-dedup-plugin`, and/or boots the restore image
under QEMU. The boot proof accepts only timeout rc 124, requires a log line
emitted by the restore daemon itself, and uses a vsock handshake when the
runner provides vhost-vsock. The full PBS restore is a lab proof, not CI.
