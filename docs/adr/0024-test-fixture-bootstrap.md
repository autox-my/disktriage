# 0024. Test fixtures are built by a tracked bootstrap

Status: accepted
Date: 2026-11-08

## Context

A fresh `git clone` did not pass the gate. About half of the live NTFS tests
read a built ntfs-3g prefix and synthetic images under
`captures/ntfs-spike/`, which is gitignored scratch: `captures/` holds real
captures with serials, and the images are 64–80 MiB of incompressible data
each. In a clean clone the tests were skipped (the gate answered 3), and one
test that built its harness unconditionally failed on a missing image (the gate
answered 1). The images themselves are synthetic — `mkntfs` plus a fixed file
set written by `ntfscp` — so the data is safe to regenerate; only its size
makes it unfit for the repository.

The old test locator also followed a worktree's `.git` file into the main
checkout and looked in that checkout's `captures/`. That made a worktree pass
on state the clone does not have.

## Decision

**Tracked generator.** `tools/ntfs-fixture/nfixture.c` is the C helper that
creates directories and removes files through libntfs-3g, because ntfsprogs has
no `mkdir`/`rm`. `tools/ntfs-fixture/generate.sh` builds every image the tests
need from a fixed, seeded file set:

- `part.img`: a 64 MiB NTFS volume (`mkntfs -T -L NTFS64 -p 2048`), populated
  with the recorded file set and filler/deletion pattern;
- `disk.img`: an 80 MiB MBR image with that volume at LBA 2048;
- `damaged-clip-part.img` and `damaged-clip-part.mapfile`: a copy with a 64 KiB
  hole at cluster 8735 and the ddrescue mapfile that reports it.

The layout is deterministic (used clusters 12308, free 4075, 10 coalesced used
runs, `$MFT` at LCN 4, `$Bitmap` at LCN 2055, `big.bin` fragmented). `mkntfs`
writes a fresh volume serial and timestamps, so the bytes differ run to run;
the tests assert layout facts, never those bytes. The images are synthetic and
contain no data from a real disk.

**One bootstrap command.** `scripts/bootstrap.sh` builds the pinned ntfs-3g
userspace tools (`scripts/lib/ntfs-3g.sh`, the same version/sha256 and configure
flags as the Homebrew formula) into `.build/ntfs-prefix`, downloads only the
sha256-verified tarball (cached under `.build/ntfs-cache`), builds `nfixture`
with the system clang, and generates the images under `.build/fixtures/ntfs`.
It is idempotent, uses no sudo, mounts nothing and never touches `/dev`. It
also checks that `ddrescue` and `smartctl` exist and names
`brew install ddrescue smartmontools` when they do not.

**One locator.** `Tests/TestSupport/TestFixtures.swift` is the only place the
tests find the prefix and images: `DISKTRIAGE_NTFS_PREFIX` /
`DISKTRIAGE_FIXTURE_DIR` first, then `<root>/.build/ntfs-prefix` and
`<root>/.build/fixtures/ntfs`. It never consults `captures/`. An environment
override is final; an incomplete one returns `nil` instead of falling back.

**The gate fails closed.** `scripts/check.sh` runs `scripts/lib/fixtures.sh` as
a preflight. When the bootstrap output is absent it prints the instruction and
exits **3** before building or testing. It never answers 0 for a silent skip
and never 1 for a missing fixture. When the output is present it exports the
two environment variables for the suite. `scripts/check-gate-probe.sh` proves
the rule with absent, complete, `captures/`-only and env-overridden roots.

## Consequences

- A fresh clone passes the gate with `scripts/bootstrap.sh` followed by
  `bash scripts/check.sh`; the same live tests run as on the author's machine.
- Without the bootstrap the gate is 3 and names the command; it is not green
  and not a code failure.
- The images live under `.build/` (gitignored) and are regenerated only when
  the generator version or the prefix changes.
- `captures/` is no longer a test dependency. The P0 probe
  `tools/p0/build-dadissent.sh` still writes its scratch output there; it is a
  manual probe, not part of the gate.
- The Homebrew formula is unchanged: the tap ships `disktriage` and the ntfs-3g
  tools, not the test fixtures.

## Requirements

- REQ-0257
- REQ-0258
- REQ-0259
- REQ-0260
- REQ-0261
- REQ-0262
