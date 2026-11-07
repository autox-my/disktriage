# 0013. Deferring slow zones (`--min-read-rate`, P3b follow-up)

Status: accepted
Date: 2026-11-07

## Context

`disktriage image` now exposes the plan's "Defer slow zones" rule
(diskdoctor.md §8). GNU ddrescue 1.30's `-a/--min-read-rate=<bytes>` is
"minimum read rate of good areas in bytes/s", so the CLI's whole MB/s is
decimal: 1 MB/s = 1,000,000 bytes/s. `-a` goes into **pass 1 only**: pass 2
(`-r3`) exists to come back to the zones pass 1 deferred, so adding `-a` there
would defeat the rule.

## Decision

- **Default.** 10 MB/s when the collected media is rotational (`hdd`) or
  unknown, because an absent media type is not evidence of flash (the USB
  bridge case). It is disabled — the flag is omitted, never `-a 0` — for SSD,
  flash, SD, NVMe and any media `MediaSupport` already calls unsupported. An
  explicit `--min-read-rate` overrides either default, including an opt-in on
  an SSD. 0 disables; anything that is not an integer from 0 to 10000 is a
  usage error (2).
- **Every surface.** The resolved bytes/s appear in the printed dry-run
  command, a `MIN RATE` line in the human plan and summary, and
  `min_read_rate_bytes_per_second` in the JSON plan and summary (an integer,
  or `null` when disabled — never 0). The command itself records the value in
  ddrescue's mapfile header.
- **Not identity.** The sidecar records `min_read_rate_bytes_per_second` as
  informational metadata, but `sidecarMatchesDevice` never compares it: the
  plan says changing it on resume is allowed, so a resume with another value
  succeeds (REQ-0183). The other sidecar fields still decide the resume.

## Consequences

- **Seams.** `defaultMinReadRateMBps(media:bus:)` and
  `minReadRateBytesPerSecond(megabytesPerSecond:)` are pure;
  `ddrescuePasses(..., minReadRateBytesPerSecond:)` builds the argv; the
  fake-ddrescue supervisor test asserts `-a 10000000` in pass 1 and its
  absence in pass 2. Mutation checks: adding
  `-a` to pass 2, applying the default to an SSD, adding the value to the
  identity check, and changing the 1,000,000 factor each turn the suite red.

## Requirements

- REQ-0178
- REQ-0179
- REQ-0180
- REQ-0182
- REQ-0184
