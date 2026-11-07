# 0016. The stage-0 scope report (`image --scope-report`, v3.8)

Status: accepted
Date: 2026-11-07

## Context

`disktriage image <disk> --to <file> --scope-report` is the plan's
"`--scope-report`" bullet (diskdoctor.md §8): run the allocation-aware
**stage 0** only, then say how much of the volume is allocated and stop. It
reuses the stage-0 read/parse path, the domain mapfile, the supervisor and every
precondition of a real run; no second ddrescue invocation is built.

## Decision

- **Stage 0 only.** The `Stage0Context` read loop is now one local
  `performStage0()` used by both the full run and the scope report. A report
  writes only the files stage 0 already writes: the image, the main mapfile,
  `<image>.domain-stage0.mapfile` and the sidecar. Stage 1 and stage 2 are never
  started, and their argv is never issued (`REQ-0221`).
- **The same gates.** The report reads the drive, so it needs the identical
  consent and safety gates as `--no-dry-run`: `--accept-risk`, root, Full Disk
  Access, the mount guard, the triage attempt, the source confirmation, the
  destination checks and ddrescue's presence (`REQ-0226`). A missing
  `--accept-risk` is the usage code **2**; a failed gate is **30**, both before
  any read. Without `--no-dry-run` it is a dry run: it prints the planned stage-0
  command (and says stage 1/2 are not run), executes nothing, and exits like the
  dry run always has.
- **The numbers are the bitmap's.** Geometry source (`primary | backup`), cluster
  size, total/used/free clusters, used/free bytes (clusters × cluster size), the
  number of used extent runs and the `$MFT`'s physical data-run bytes
  (`REQ-0222`). The used extent count is the bitmap's coalesced run count — 10 on
  the spike image, matching the recorded `ntfscluster` cross-check — not a count
  of read extents. Free bytes are cluster-granular, so the volume's trailing
  partial sector is not counted as free.
- **ETA.** The existing `assumedBusSpeed`/`etaRange` pair is applied to the
  **used** bytes, because stage 1 reads exactly those; the basis string is
  printed verbatim and carried in JSON (`REQ-0223`). The ~48 s cost of a failed
  block on macOS is stated as a sentence only: no number is added to the ETA and
  no failed-block count is invented before a read.
- **Failure is nothing learned.** A typed stage-0 failure prints the reason on
  stderr and exits **1**, with no scope numbers and no fallback passes
  (`REQ-0224`). A launch failure is **30** (a tool error); an interrupt or a
  vanished device is **1** (resumable, nothing learned). `--scope-report` with
  `--used-only` is a usage error (**2**), because a scope report never reaches a
  used-cluster stage (`REQ-0225`).
- **JSON.** `--json` prints `status`, `image`, `mapfile`, `sidecar`, `partial`
  and a `scope_report` object with the stable keys `geometry_source`,
  `cluster_bytes`, `total_clusters`, `used_clusters`, `free_clusters`,
  `used_bytes`, `free_bytes`, `used_extents`, `mft_bytes`, `eta_low_seconds`,
  `eta_high_seconds`, `eta_basis`. An ETA that cannot be computed is `null`,
  never omitted and never 0. With `--limit`, the top-level `limit_bytes` and
  `used_bytes_inside_limit` report the used bytes inside the limit separately,
  while `used_bytes` stays the whole allocation.
- **Sidecar.** `scope_report` is an additive optional object with the same twelve
  keys (null ETA is an explicit `null`); `allocation` is `allocation-aware`,
  `stage0: done`, `stage1`/`stage2: not-started`, and the recorded `command` is
  the stage-0 read only. A later full run reads the sidecar, re-runs stage 0
  cheaply as always and continues at stage 1 (`REQ-0227`). A failed report stores
  the reason and no scope numbers.

## Consequences

- **Tests.** `DiskTriageCLITests.ScopeReportTests` drives the fake-ddrescue
  domain seam on a copy of the gitignored `captures/ntfs-spike/img/disk.img`:
  stage 0 only and no stage-1/2 argv, the recorded 16383/12308/4075 clusters,
  50,413,568/16,691,200 bytes, 10 used extents and 126,976 `$MFT` bytes, the
  backup boot sector, a zeroed bitmap (exit 1, reason, no numbers), `--limit`,
  the sidecar and the later full-run resume. One real ddrescue 1.30 test runs the
  same report on a regular-file copy of the capture. It is `<skipped>` when
  ddrescue or the capture is absent, which the gate answers as **3**, never a
  pass.
- **Mutation checks.** (a) letting the report fall through to a full run turned
  the stage-0-only test red, (b) swapping used and free turned the number tests
  red, (c) removing the bitmap/`$MFT` consistency guard turned the bitmap-failure
  test red (it printed numbers and exited 0), and (d) neutering the consent
  blocker turned the gate test red (it read without `--accept-risk`). Restoring
  each turned the suite green.
- **Judgement calls.** `$MFT` bytes exclude `$MFTMirr` (they are the `$MFT`
  `$DATA` runs). The JSON limit composition lives at document top level, so the
  twelve `scope_report` keys stay stable. A scope report stores
  `mode: whole-device` and no stage-1/2 state when stage 0 fails, because no
  fallback pass ran. No change is made to `diskdoctor.md`; the above are
  findings.

## Requirements

None. No claim's `rationale.source` points at this record; the claims the body
names cite `diskdoctor.md` §8.
