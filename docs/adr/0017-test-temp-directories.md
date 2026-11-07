# 0017. Test temp directories are removed, and the gate notices when they are not (v3.9)

Status: accepted
Date: 2026-11-07

## Context

The suite used to leak its working directories: after the scope-report work
`getconf DARWIN_USER_TEMP_DIR` held 1,589 `disktriage-*` directories (about
22 GiB), the disk filled to 1.3 GiB free, and image and gate runs failed. The
fix is one helper and one gate rule, not a cleanup script.

## Decision

- **One helper.** `Tests/TestSupport/TempDir.swift` (the `DiskTriageTestSupport`
  target, test-only) creates a unique `disktriage-tests-<uuid>` directory under
  `FileManager.default.temporaryDirectory`. Its `deinit` removes the tree, so a
  test struct's `private let temp = TempDir()` cleans up when the test returns —
  passing, failing or throwing. Removal first makes every item writable (a
  `0500` destination or a `0400` snapshot is legitimate fixture data), then
  removes the tree. No test creates a directory with `FileManager` or
  `NSTemporaryDirectory` directly any more; a harness holds its `TempDir` so
  its lifetime covers the test.
- **Every suite is converted**, including the capture-backed fake-ddrescue and
  real-ddrescue harnesses, `copy`'s sparse 16 MiB images, the NTFS tool
  prefixes, the process-runner marker directories and the built-binary seams.
  Images that used to land in `/tmp` (`/tmp/disktriage-test-<uuid>.img`) are
  inside a per-call `TempDir` too.
- **The leak guard.** `scripts/lib/temp-leak.sh` lists the `disktriage-*`
  directories directly under `getconf DARWIN_USER_TEMP_DIR` and `$TMPDIR` (once
  each, when they exist). `scripts/check.sh` snapshots before the runner starts
  and after it exits. A directory that appears only after the run is **FAIL
  (exit 1)**, with its count and paths, even when the tests themselves were
  skipped (3) — a real failure beside a skip is still a failure. A directory
  already present is a **warning only** and the gate never deletes it: it is
  not the gate's property.

## Consequences

- **The probe proves it bites.** `scripts/check-gate-probe.sh` builds a fake
  temp root under its own `mktemp` directory: a pre-existing entry plus no new
  one answers 0 with the warning, and a faked `disktriage-new-leftover` answers
  1 naming it, never touching a real leftover. Mutation check: re-introducing
  one leaked directory in a test call site turned the gate red with that path;
  restoring it turned the gate green.
- **The gate's own temp files** (`mktemp -d` for the logs and the probe) are not
  named `disktriage-*`, so they are not counted; the leak guard measures the
  suite, not the harness.

## Requirements

- REQ-0228
- REQ-0229
- REQ-0230
- REQ-0231
- REQ-0232
