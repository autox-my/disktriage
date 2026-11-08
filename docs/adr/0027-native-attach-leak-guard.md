# 0027. The gate fails on a leaked native attach or mountpoint

Status: accepted
Date: 2026-11-08

## Context

The native live tests attach real images and mount them read-only. A leaked
attachment keeps a `/dev` node and a kernel filesystem alive after the suite; a
leaked mountpoint directory is the same bug in a different form. The existing
gate already fails on a leaked `disktriage-*` temp directory
(`scripts/lib/temp-leak.sh`, ADR [0017](0017-test-temp-directories.md)) and a
skipped test is never a pass.

## Decision

- **A native leak is FAIL (1).** After the suite, `scripts/lib/native-leak.sh`
  scans `hdiutil info` for an image path containing `disktriage` and `mount`
  for a `disktriage-mount-*`/`disktriage-tests-*` line. Any hit is printed and
  fails the gate. The gate never detaches or deletes the leftover: it must not
  guess which disk is safe to eject.
- **A scan that cannot run is UNVERIFIABLE (3).** A missing `hdiutil` or
  `mount` is exit 3, never a pass. A failure still outranks it.
- **The probe proves it bites.** `scripts/check-gate-probe.sh` drives the
  verdict with fake scan files: empty is 0, an image path is 1 and names the
  image, a mountpoint is 1 and names the mountpoint, and an `UNVERIFIABLE` scan
  is 3. No real leftover is created.
- The live tests copy each fixture into their own temp directory before
  attaching, so a leaked image path contains `disktriage-tests-*` and the scan
  can see it.

## Consequences

- A crashed or interrupted live test greys or fails the gate instead of hiding.
- The scan is read-only and idempotent; it adds a few milliseconds.
- **Not covered:** an attach whose `hdiutil info` path has been unlinked or
  rewritten to a name without `disktriage` (a test-owned copy always keeps the
  temp path), and a mount whose mount table line was truncated. Those are
  named limits of a path-based guard.

## Requirements

- REQ-0276
- REQ-0277
- REQ-0278
