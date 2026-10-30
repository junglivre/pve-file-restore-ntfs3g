# Test fixtures

## `fixtures/ntfs-dedup-2`

The synthetic Windows Server Data Dedup fixture is published as the
`fixtures/ntfs-dedup-2` release in `junglivre/pve-file-restore-ntfs3g`. CI
downloads its four assets:

- `ntfs-dedup.img.zst`, a bare NTFS partition image;
- `ntfs-dedup.img.zst.sha256`, the image checksum;
- `manifest.sha256`, UTF-8/LF entries in the form `<sha256>  <relative path>`;
- `dedup-files.txt`, the nine Dedup reparse-point paths.

The image is not stored in this repository. A local reference copy is kept in
the lab fixture directory. `tests/fixture/run.sh` verifies the image checksum,
requires a successful read-only mount, and checks that without the plugin only
the nine listed Dedup paths fail, while with the plugin all eleven entries
match.

## What CI does

Every pull request runs `tests/run-all.sh`, which runs ShellCheck, actionlint,
and every unit-test suite. When a component or proof input changes, the
artifact job verifies the packages, tests the metapackage against official and
patched APT repositories, runs the fixture with and without the plugin, and
boots the restore image under QEMU. The boot proof accepts only timeout rc 124
and requires a log line emitted by the restore daemon itself.
