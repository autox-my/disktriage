# 0019. An unfinished `$Bitmap` byte is unknown allocation, never free (v3.9)

Status: accepted
Date: 2026-11-07

## Context

The first real `--scope-report` run on the MiNaH drive (`captures/minah-scope/`)
ended stage 0 with `$Bitmap data: ddrescue stopped on its own, exit 1;
continuing with the image's bytes`. The tool parsed the zero-filled bitmap
anyway, so 4096 unreadable bitmap bytes read as "all 32,768 clusters free"
(about 128 MiB at the volume's 4 KiB clusters). The scope reported 18,033,658
free clusters of which 32,768 were unknown, and `--used-only` would have
skipped them. `diskdoctor.md` §8 says the tool "never marks free space as
unneeded without having read the bitmap"; a zero-filled stretch is not the
bitmap.

## Decision

- **The main mapfile is the evidence.** After each stage-0 read the tool parses
  the main mapfile (the same clamp-aware `DdrescueMapfile`) and treats every row
  that is not `+` as unfinished. `NTFSBitmapTrust.unreadable(bitmapRuns:
  unfinished: clusterBytes: totalClusters:)` is the pure intersection: it keeps
  the bitmap runs in **stream** order (the byte index is the sum of the runs
  before it, never the run-local offset), reports the untrustworthy bitmap byte
  ranges, and maps each byte to clusters `8n ... 8n + 7`, clipped to the volume.
  An absent or unparsable mapfile trusts nothing (whole-device fallback).
- **Unknown is used for stage 1, absent from stage 2.** The unknown clusters are
  added to the domain's `used` extents, so a `--used-only` run still images
  them, and the stage-2 complement cannot contain them. The bitmap's own
  `usedClusters` stay separate: the report keeps `used_*` as the bitmap's
  trustworthy count, adds `unknown_clusters`, `unknown_bytes`, `unknown_extents`
  and `bitmap_unreadable_bytes`, and `free_*` is the bitmap-free clusters that
  were actually read. `stage1_clusters`/`stage1_bytes` are used + unknown, and
  the ETA is computed from `stage1_bytes`; the NOTE says so.
- **The real numbers.** `Tests/Fixtures/minah-scope-mapfile.txt` is
  `mapfile-final.txt` with its local paths redacted; `minah-scope-notes.md`
  records the arithmetic. The bitmap data run is one extent,
  `0x2542E8A000..0x25437DB000`, and the three non-`+` rows inside it
  (`0x600`, `0x800`, `0x200`) total 4096 bytes from bitmap byte 4,681,728, or
  32,768 clusters. Before: used 60,108,549, free 18,033,658, ETA 2.28–2.74 h at
  the old 25–30 MB/s assumption. After: used 60,108,549 + unknown 32,768, free
  18,000,890, stage 1 60,141,317 clusters (246,338,834,432 bytes), unknown 128
  MiB, ETA 1.85–2.28 h at 30–37 MB/s.
- **Metadata other than the bitmap is not guessed at.** A boot sector is chosen
  only from the primary or backup sector the mapfile finished: an unfinished
  primary falls back to the backup (the MiNaH case), and neither finished is a
  typed stage-0 failure naming the boot sector. An unfinished `$MFT` record 0
  or `$Bitmap` record 6 is the same typed failure with the structure named
  (whole-device fallback in a full run, exit 1 with no numbers in a scope
  report). Other records 1–15 are counted and printed as
  `unreadable metadata records: N`; they are never used.
- **More than 10 percent is a fallback.** When the unreadable bitmap bytes
  exceed 10 percent of `$Bitmap`'s data size, the allocation-aware order cannot
  buy anything, so stage 0 fails with that reason and the run uses the plain
  whole-device passes.
- **The ETA assumption now has a measured basis.** `assumedBusSpeed` uses
  30–37 MB/s for USB 2 with the basis `assumed USB 2: 30–37 MB/s (37 MB/s
  measured on a clean zone of the MiNaH drive)`, from `captures/minah-image/`
  (557 MB in 15 s). The bus-unknown default carries the same measured basis.
  `ImageCommandTests.REQ0087_etaRangeIsPrinted`, `ImagingRulesTests`
  `REQ0087_etaIsARange` and `ScopeReportTests`' JSON ETA expectations moved with
  it; the old "not measured" assertion became "measured".

## Consequences

- **Tests.** `DiskTriageCoreTests.NTFSBitmapTrustTests` is table-driven: none, a
  16-byte sub-sector hole, one hole straddling two bitmap runs (the cumulative
  offset case), and a hole past the bitmap end clipping at the volume's last
  cluster; plus the domain test that unknown clusters join stage 1 and leave
  free. `DiskTriageCLITests.ScopeUnknownBitmapTests` parses the redacted real
  mapfile (4096 bytes, 32,768 clusters), drives the fake ddrescue on a copy of
  `captures/ntfs-spike/img/disk.img` with a 16-byte hole in the bitmap data
  (zeroed source, `-` row through the new `badRanges` seam), and asserts stage 1
  contains clusters 3800–3927, stage 2 does not, `--used-only` still images
  them, the UNKNOWN line, the JSON and sidecar keys, the 10 percent fallback,
  the boot-sector backup, and records 0, 6 and 7.
- **Mutation checks.** (a) counting unknown clusters as free in the report
  (`free = total − used`) turned the report test red; (b) removing them from the
  domain's `used` turned the pure and end-to-end stage-1 tests red; (c) adding
  them to the free complement turned the pure test red, and building stage 2
  without excluding them turned the end-to-end test red; (d) removing the
  10 percent check turned the fallback test red; (e) using the run-local offset
  instead of the cumulative stream offset turned the two-run table case red.
  Restoring each turned the suite green.
- **Judgement calls and plan gaps.** `free_*` is now the trustworthy free count
  (`total − used − unknown`), so used + unknown + free is the volume; the plan
  only names used and free. `unknown_extents` is the number of untrustworthy
  bitmap byte runs (one for the real three adjacent rows). A hole that covers
  only `$Bitmap` padding bits still counts in `bitmap_unreadable_bytes` but adds
  no unknown cluster; that is reported, not hidden. Stages 1 and 2 derive the
  domain from the same `used` extents, so an unknown cluster cannot be in one
  and not the other. `$ATTRIBUTE_LIST` stays unsupported; a fragmented `$MFT`
  whose records do not start in the first run still relies on the first 16-record
  region. No change is made to `diskdoctor.md`; the above are findings.

## Requirements

- REQ-0238
- REQ-0239
- REQ-0240
- REQ-0241
- REQ-0243
- REQ-0244
- REQ-0246
