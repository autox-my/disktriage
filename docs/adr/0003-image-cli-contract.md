# 0003. CLI decisions (P3b)

Status: accepted
Date: 2026-11-07

## Context

P3b adds the supervised ddrescue image path. It needs a CLI contract for
`disktriage image ... --no-dry-run`: exit codes that are not the verdict codes,
the split between a usage error and a precondition failure, partial imaging with
`--limit`, and a sidecar that is the resume authority.

## Decision

- `image --no-dry-run` exits **0** when both passes finish, **1** when it
  stopped by the pass-2 rule, a device disappearance, an interrupt or a
  ddrescue error (all resumable), and **30** for a precondition/tool error.
  These are deliberately not the verdict codes.
- A missing `--accept-risk` is a **usage error (2)**: it is a flag, not an
  environment fact. Root, FDA, the mount guard, ddrescue and the dry-run
  checks exit **30**.
- FDA `UNKNOWN` blocks imaging as well as `DENIED`: an unverified grant is not
  a pass (plan §7), even though the brief only named `DENIED`.
- The resume command printed on an incomplete image is the
  `disktriage image ... --no-dry-run` command, not the raw ddrescue line:
  ddrescue resumes from the mapfile, and the wrapper re-runs the same
  preconditions.
- The sidecar (`<image>.disktriage.json`) is rewritten at each run start
  (`created_at` is this attempt) and records both pass argv; the device
  identity fields remain the resume authority.
- "Complete" means both passes exited 0. Bad sectors can remain (`-` extents);
  they are reported as bad bytes and are zero-filled in the image, not treated
  as an incomplete run.
- **`image --limit <GiB>` is partial imaging.** The value is a positive whole
  number of GiB (2^30 bytes); zero, a fraction, a negative number, a non-number
  or a missing value is a **usage error (2)**. A limit at or above the device
  size is the full device, so it is not labelled partial and carries no `-s`.
  When partial, both ddrescue passes get `-s <bytes>`; the human plan and the
  JSON plan say `PARTIAL (N GiB of M GiB)`; the free-space gate checks the
  limit while still naming the whole device; and the ETA is for the limit.
- The **size confirmation is still the whole device** (`--confirm-size <GiB>` or
  the serial's last four), never the limit: the limit is how much is read, not
  which disk it is.
- The sidecar records `limit_bytes` (absent for a full image). It is part of the
  resume authority: a different limit, or a full-versus-partial change, is
  refused with **exit 30** and a message naming both the recorded and requested
  extent, before any read.
- A partial run that finishes is reported as **`partial image complete (first N
  GiB)`** in the human summary and in JSON (`status` and `stopped`), never as a
  complete image of the device. The exit codes are unchanged: 0 complete, 1
  incomplete-resumable, 30 precondition. The pass-2 stop rule's 0.01% threshold
  and remaining-time projection use the limited size.
- The limit is whole GiB on the CLI. The byte value is injectable at
  `image(..., limitBytesOverride:)`, the seam the tests use for a sub-GiB file
  smoke; no fractional CLI flag exists.
- **Mapfile accounting for a partial image is clamped to `[0, limit)`.** GNU
  ddrescue 1.30 with `-s` leaves the untried tail ending at `Int64.max`
  (`0x7FFFFFFFFFFFFFFF`), so an unclamped mapfile reports ~8.6 billion GiB
  remaining. Every extent is clipped to the range, an extent starting at or
  after the limit is dropped, and `rescued`, `bad`, `remaining`, the extent
  count and the percentage are computed inside it (`remaining = limit - rescued
  - bad`). A full image keeps the mapfile's own extents exactly as before. The
  pass-2 stop rule and the complete/incomplete decision use the limited size,
  clamped numbers and ddrescue's exit code — never the unbounded tail.

## Consequences

These exit codes are deliberately not the verdict codes. The sidecar's device
identity fields remain the resume authority, and `--limit` is part of that
authority: a different limit, or a full-versus-partial change, is refused with
exit 30 before any read. The pass-2 stop rule and the complete/incomplete
decision use the limited size, clamped mapfile numbers and ddrescue's exit
code — never the unbounded tail.

## Requirements

- REQ-0101
- REQ-0107
- REQ-0109
