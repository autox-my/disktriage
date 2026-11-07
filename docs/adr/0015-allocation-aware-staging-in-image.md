# 0015. Allocation-aware NTFS staging is wired into `image` (v3.8)

Status: accepted
Date: 2026-11-07

## Context

`disktriage image` now runs the plan's allocation-aware order (diskdoctor.md §8)
by default. The live dependency set enables it; the pure library is unchanged
except for the bitmap-consistency guard below.

## Decision

- **Stage 0, metadata.** ddrescue runs with a small
  `<image>.domain-stage0.mapfile` (the same main mapfile, so resume is free):
  the partition table (LBA 0, plus the GPT header and entry array and their
  backup copies), the primary boot sector, the backup sector at
  `partition_offset + partition_length - 512`, then the first 16 `$MFT`
  records and the `$Bitmap` data runs. The bytes are read back out of the image
  and parsed; the primary boot sector wins, the backup is used only when the
  primary is invalid, and the report names which (`geometry_source`). **No
  `-n`, `-r3` or `-a` in stage 0**: these are small targeted reads.
- **Stage 1, used clusters.** The library's used domain is written to
  `<image>.domain-stage1.mapfile`; `ddrescue -n -m` runs with `-a` in pass 1
  only, then `ddrescue -r3 -m` with no `-a`, under the existing pass-2 stop
  rule. The partition table and boot sectors stage 0 already read stay `+` in
  the main mapfile.
- **Stage 2, the rest.** The **whole-device** complement of the used domain
  (not only the volume's free clusters), so a default run reproduces the
  device byte for byte, including bytes outside the partition. `--used-only`
  skips it and the summary says so.
- **`--limit` composes with every stage.** Every domain mapfile is clipped to
  `[0, limit)` before it is written, and the stage commands carry the same
  `-s`. A partition that starts beyond the limit, or a bitmap that reaches past
  it, is a stage-0 failure and falls back.
- **Fallback is whole-device, with the reason.** Not an NTFS partition table,
  both boot sectors invalid, a torn MFT record, an `$ATTRIBUTE_LIST`, a
  missing/short/overlapping bitmap or a geometry outside the partition prints
  one reason, stores it in the sidecar (`allocation.stage0_reason`) and runs
  the old plain two-pass sweep. **Unknown is never "free space is unneeded."**
  A zeroed `$Bitmap` parses as "nothing used"; the library now rejects a bitmap
  that does not mark the `$MFT`'s own clusters used
  (`mftClustersNotMarkedUsed`), so that case falls back instead of skipping
  everything.
- **Sidecar.** `allocation` is an additive optional object:
  `used_only`, `mode` (`allocation-aware | whole-device`), `stage0`
  (`not-started | done | failed | interrupted`), `stage0_reason`,
  `geometry_source`, and `stage1`/`stage2`
  (`not-started | pass1 | pass2 | done | skipped | plain`). A resume re-runs
  stage 0 from the image (cheap and safer) and starts stage 1 or 2 at the
  recorded pass; a completed stage is not redone. A different `--used-only`
  value is allowed; a different `--limit` is still refused.
- **Reporting.** Human and JSON carry the stage lines and a `SCOPE` line:
  `used clusters + metadata (free space NOT imaged: --used-only)`,
  `whole device`, or `whole device (allocation unknown: <reason>)`. A finished
  `--used-only` run is `used-only image complete (free space not imaged)` and
  never `complete`. Progress lines say `% of scope` for a stage; the
  whole-device rescued/failed/bad/remaining numbers stay in JSON (`rescued_*`,
  `failed_*`, `bad_*`, `remaining_*`) beside the `scope_*` numbers.
- **Dry run.** It prints the exact stage 0 read command, the two stage-1 and
  two stage-2 commands, and keeps the plain two-pass lines as the explicit
  `FALLBACK`. Stage 1/2 domains say `domain computed from the bitmap`: the
  command line is knowable before a read, the bitmap's extent content is not.

## Consequences

- **Tests.** `DiskTriageCLITests.NTFSAllocationImageTests` drives the whole
  flow through a fake ddrescue that copies the domain mapfile's `+` extents
  from a copy of the gitignored `captures/ntfs-spike/img/disk.img`: stage
  order, the stage-1 domain equals the library's used domain, `-a` in pass 1
  only, every stage domain inside `--limit`, `--used-only` with no stage 2, a
  non-NTFS fallback, a zeroed-bitmap fallback, the sidecar state, resume after
  an interruption at stage 0, 1 and 2, and the scope wording. The pure scope
  accounting and the dry run are unit-tested. `NTFSAllocationImageLiveTests`
  runs real ddrescue 1.30 on the capture: default staging sha256-equals the
  source; `--used-only` matches every used cluster and leaves free clusters
  zero; a zeroed primary boot sector uses the backup and still matches every
  used cluster. These are `<skipped>` when ddrescue or the capture is absent,
  which the gate answers as **3**.
- **Mutation checks.** (a) not skipping stage 2 with `--used-only`, (b) not
  falling back after a failed bitmap parse (free space skipped), (c) not
  clipping a stage domain to `--limit`, (d) ignoring the backup boot sector,
  (e) adding `-a` to pass 2, and (f) calling a `--used-only` image `complete`
  each turned the named test red; restoring each turned it green.
- **Judgement calls and plan gaps.** Stage 2 is the **device** complement, so a
  default run is byte-identical to the source; the plan says "the rest of the
  volume". The bitmap/MFT consistency guard (REQ-0210) is an addition the plan
  does not spell out; without it a zeroed bitmap is a valid all-free bitmap.
  Stage 0 assumes records 0-15 start at the `$MFT` LCN; record 6 is located
  through the run map and read separately when a fragmented `$MFT` puts it
  outside that region. The "allocation-aware" switch is a
  `ImagingDependencies` flag: `.live` enables it, and a hand-built dependency
  set (the older fake tests) keeps the plain path unless it opts in. No change
  is made to `diskdoctor.md`; the above are findings.

## Requirements

- REQ-0207
- REQ-0208
- REQ-0209
- REQ-0211
- REQ-0212
