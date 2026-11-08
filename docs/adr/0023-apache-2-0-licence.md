# 0023. Apache-2.0 licence

Status: accepted
Date: 2026-11-08

## Context

The repository is about to be published publicly, and a public repository
without a licence is not distributable: the default is all rights reserved.
The formula template already declares `license "Apache-2.0"`; ADR
[0022](./0022-homebrew-packaging.md) recorded the earlier state, when there was
no `LICENSE` file and the formula used `license :cannot_represent` as a
deliberate placeholder. That placeholder is now stale.

The project invokes three GPL tools as subprocesses: `ddrescue`,
`smartmontools` and `ntfs-3g` (ntfsprogs). None is linked into `disktriage` and
none is bundled in the repository; the Homebrew formula builds ntfs-3g from
source into its own `libexec` and the binary links no ntfs-3g or FUSE library.

## Decision

The project is licensed under **Apache-2.0**. `LICENSE` carries the Apache
License 2.0 text and `NOTICE` names the copyright holder and the GPL
subprocesses.

`packaging/homebrew/Formula/disktriage.rb` declares `license "Apache-2.0"`; the
`:cannot_represent` placeholder is gone. The GPL tools remain separate
processes, not linked into or bundled with `disktriage`; `NOTICE` states this
and the formula comment repeats it.

## Consequences

- `docs/packaging.md` no longer lists the licence as a human-only blocker.
- The README states the licence and the GPL subprocess boundary.
- The licence is a repository fact, not a runtime behaviour, so the evidence is
  the files themselves (`LICENSE`, `NOTICE`, the formula line), not a Swift
  test. The earlier packaging claims (REQ-0252–REQ-0256) keep their process
  evidence.
- Choosing a different licence later is a new ADR; it does not rewrite this
  one.

## Requirements

- REQ-0263
- REQ-0264
