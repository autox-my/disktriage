# 0018. The scope report's destination needs metadata room, not the device (v3.9)

Status: accepted
Date: 2026-11-07

## Context

`disktriage image disk0 --to <file> --scope-report` used to refuse on a 233.8 GiB
device with 1.3 GiB free, although a scope report writes stage 0's few MB into a
sparse image: the apparent size is large because the backup boot sector sits
near the partition end, but the allocated blocks are only the metadata.

## Decision

- **Only APFS changes.** `filesystemSupportsSparseFiles` accepts exactly `apfs`
  (from `statfs.f_fstypename`). Every other filesystem, and an unknown one, keeps
  the full-size rule unchanged.
- **The rule.** For a scope report on APFS the free-space requirement is
  `max(1 GiB, 2 × NTFSStage0ReadPlan.scopeReportByteBudget(deviceBytes:))`. The
  budget is a pure upper bound on the stage-0 read (the whole `$Bitmap` at one
  bit per 512-byte cluster, plus a 2 MiB fixed-metadata bound), not a
  measurement; `if available` means a nil source size falls back to the 1 GiB
  floor. A pass prints
  `sparse image on apfs: scope report writes metadata only (~N MiB)`; a refusal
  prints the free and required numbers beside the same sentence.
- **Unchanged.** The "not on the source disk" and writable rules are untouched.
  Every mode that is not a scope report — a full dry run, a full run,
  `--used-only`, and a partial limit — keeps the full-size (or limit) rule on
  APFS, and the CLI passes `scopeReport` to the one assessment so there is no
  second copy of the rule.

## Consequences

- **The real-file proof.** `ScopeReportLiveTests` runs real ddrescue 1.30 on the
  capture with a 233.8 GiB source size in the seam and 1.3 GiB free: the only
  run that passes is the scope report, and its image's `st_blocks` (allocated)
  is far below its apparent size. On a host whose temp directory is not APFS,
  or without ddrescue or the capture, the test is `<skipped>`, which the gate
  answers as 3, never a pass.
- **Mutation checks.** (a) applying the scope rule to every run turned the
  full/`--used-only` tests red, (b) treating a non-APFS filesystem as
  sparse-capable turned the HFS/exFAT/MS-DOS test red, and (c) removing the
  1 GiB floor made the half-gigabyte destination pass. Restoring each turned the
  suite green. No change is made to `diskdoctor.md`; the pre-read budget is an
  addition the plan does not spell out.

## Requirements

- REQ-0233
