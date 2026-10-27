# Test fixtures

## `fixtures/ntfs-dedup.img.zst` (not yet committed)

A small NTFS volume image with Windows Server Data Deduplication enabled and
only synthetic files. Created once, manually, on a lab Windows Server:

1. Create a small VHDX, format it NTFS, enable Dedup
   (`Enable-DedupVolume`), copy synthetic text/binary files onto it and run
   `Start-DedupJob -Type Optimization`. Wait until the files are reparse
   points (`System Volume Information/Dedup` exists).
2. Record the expected checksums of the deduplicated files in
   `fixtures/ntfs-dedup.sha256` (paths relative to the volume root).
3. Detach, compress: `zstd -19 ntfs-dedup.img`, commit both files.

**The fixture contains only synthetic files. Never put client data in it.**

## What CI does with it

`build.yml` mounts the image read-only with `ntfs-3g` in a Debian 13
container that has the freshly built `ntfs-3g-plugin-dedup` installed, then
runs `sha256sum -c fixtures/ntfs-dedup.sha256`. Wrong content from a missing
or broken plugin fails the job.

While the fixture is absent, the step is skipped with a warning.
