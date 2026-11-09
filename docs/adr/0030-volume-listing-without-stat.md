# 0030. The removable-volume row lists `/Volumes` by name, under a hard bound

Status: accepted
Date: 2026-11-09

## Context

`disktriage check` blocked for 160–260 s on the development Mac, which violates
the rule that the tool must not hang with the disk. The block was in the
self-test's removable-volume row, not on a target device: `/Volumes/fadhli` is
a hung WebDAV mount on this host.

Measured on 2026-11-09:

- `stat /Volumes/fadhli` never returns.
- `ls -f /Volumes` returns the entry names instantly, because it reads the
  directory with `readdir` and asks for no entry's attributes.
- `FileManager.contentsOfDirectory(atPath: "/Volumes")` blocks with the mount.
  The whole-check test took 160–260 s instead of its 5 s bound, and the row
  could not distinguish a hung listing from a readable one.

A row that must read `/Volumes` therefore cannot resolve entry metadata, and
must not let even a name-only listing run without a bound.

## Decision

- **Names only.** The row lists `/Volumes` with `opendir`/`readdir` and returns
  the entry names. It does not call `contentsOfDirectory`, stat an entry, ask
  for resource values, or resolve a symlink. `"."` and `".."` are not volumes
  and are not counted.
- **A hard bound of 2 s.** The listing runs on a worker thread and the row
  stops waiting after 2 s. The stuck worker is abandoned, not joined: a kernel
  call stuck on a hung mount cannot be cancelled, and the self-test must
  return.
- **A timeout is UNVERIFIABLE, never PASS.** The row reads
  `UNVERIFIABLE /Volumes did not answer within 2 s (hung mount?)`. A listing
  error is `FAIL cannot list /Volumes: <reason>`; a listing that returns names
  is `PASS /Volumes lists <n> entries`. An absent signal is never a zero.

## Consequences

- The whole check returns in milliseconds beside the hung mount instead of
  minutes. The seam test injects a lister that blocks and a 0.2 s bound, and
  asserts the row is UNVERIFIABLE within the test's own bound; a second test
  drives the real `POSIXVolumeLister` over a temp directory holding a directory,
  a dangling symlink and a FIFO, proving names are returned without resolution.
- The abandoned worker is a deliberate cost. On a healthy machine it exits at
  once; on a hung mount it remains blocked until the process exits, and a
  short-lived `check` process makes that acceptable.
- No test can prove the absence of a per-entry stat against a genuinely hung
  mount: building one is neither portable nor safe in the suite. The rule is
  carried by `POSIXVolumeLister` containing no per-entry calls, and by the
  timeout that keeps even a bad implementation bounded.
- The 2 s bound is a judgement, not a measurement: a local `readdir` is
  instantaneous, and the row exists to tell GRANTED from DENIED, not to wait on
  a sick filesystem.

## Requirements

- REQ-0321
- REQ-0322
