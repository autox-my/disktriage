# 0012. `check` does not wait on a stopped diskarbitrationd (P3 follow-up)

Status: accepted
Date: 2026-11-07

## Context

`disktriage check` did not return within 120 s with `guard --suspend` active,
even though the `diskutil listFilesystems` row already skipped. The audit found
the remaining blocker: `mountGuardAvailable` called `DASessionCreate`, a
synchronous DiskArbitration call that talks to the stopped daemon with no
timeout.

## Decision

- **The rows that touch DiskArbitration ask first.** `mount-guard` returns
  `UNVERIFIABLE diskarbitrationd stopped; DASessionCreate skipped`; the
  filesystem row keeps `diskarbitrationd stopped; diskutil skipped`. Both use
  the same `DiskArbitrationProbe` (a positive `T` state from `pgrep`/`ps`) as
  the collector and the image path; a failed probe falls through, so an
  unreadable state is never treated as a guard.
- **Everything else runs or is bounded.** The raw-device row reaches
  `DeviceCollector`, which uses ioreg while stopped and never `diskutil`. The
  tool rows run `--version` under the check policy's hard timeout. The unified
  log probe has its hard timeout. The `diskarbitrationd state` row now runs its
  `pgrep`/`ps` through the injected runner with the runner's hard timeout,
  instead of a bare `Process` with no deadline.
- **The ntfs-3g row names what it searched.** The real run printed
  `missing ntfsls, ntfscat` while `inspect` found `ntfsls` under the same
  prefix. Resolution was already shared; the row collapsed every non-PASS
  into "missing" and printed no path. `ntfsls --version` prints its banner and
  **exits 1**, so a present binary looked absent. A found ntfs tool whose
  `--version` exits non-zero is now `PASS` when it printed its banner (or
  `UNVERIFIABLE` when it printed nothing), and a genuinely missing tool's
  message names `DISKTRIAGE_NTFS_PREFIX`, PATH and the fallback directories.

## Consequences

- **The seam test.** No test stops a system daemon. One test injects a runner
  where every diskutil shape returns a timeout and `pgrep`/`ps` report `T`,
  then runs the whole `CheckRunner`: both DiskArbitration rows are
  UNVERIFIABLE with the reason, no diskutil command is attempted, and the
  run completes in well under 5 s. There is still no in-process timeout for
  `DASessionCreate` when the daemon is running but wedged; the skip covers the
  measured failure, and a wedged-but-running daemon is a finding, not a pass.

## Requirements

- REQ-0168
- REQ-0174
- REQ-0175
- REQ-0176
