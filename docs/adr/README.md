# Architecture decision records

An ADR records **one decision area**: why a contract is what it is, what was
chosen, and what follows from it. These records exist because the SDLC page
([`docs/sdlc.md`](../sdlc.md)) is the workflow — the gate, the TDD loop,
fixtures, the definition of done, commits and review — and a decision log
appended to it made the workflow impossible to read.

The form is Michael Nygard's: a numbered file with `Status`, `Date`,
`Context`, `Decision`, `Consequences`, plus a local `Requirements` section that
names the claims whose `rationale.source` points here. Records are written once
and kept: a later decision that genuinely replaces an earlier one gets a new
number and the old record's `Status:` becomes `superseded by NNNN`. Do not
rewrite history to agree with the code.

## When to write one

Write an ADR when a decision:

- changes a contract others can observe — a CLI flag or exit code, a JSON or
  manifest key, a sidecar field, a file format, a retention or permission rule,
  a safety rule, or the gate's own verdict rule;
- is a measurement or a platform fact a future reader would otherwise have to
  reverse-engineer from the code or the transcripts; or
- deliberately chooses one option over another and the rejected option would
  otherwise look like an oversight.

Implementation details that merely follow `diskdoctor.md` do not need an ADR.
A new feature starts as a change to the plan, not as an ADR.

A new decision is a **new file** with the next number, never an append to
`docs/sdlc.md`. Name it `NNNN-short-slug.md` in lower-case hyphenated form.

## Template

```markdown
# NNNN. Title

Status: accepted
Date: YYYY-MM-DD

## Context

What the plan required, what the platform measured, and what made the decision
necessary. Facts and measurements, not advocacy.

## Decision

The rule that was chosen, in the present tense. Exit codes, keys, sizes,
timeouts and thresholds live here verbatim.

## Consequences

What follows: the tests that prove it, the gate outcome, the deliberate
non-goals, the judgement calls and the plan gaps. A cost stated here is a cost
the project accepted.

## Requirements

- REQ-NNNN
```

Use `Status: superseded by NNNN` when a later record replaces this one. A record
that is merely extended by a later one stays `accepted`; the later record says
what it adds.

## Index

| Number | Title | Status | Date |
|---|---|---|---|
| [0001](0001-cli-usage-codes-and-recorded-signals.md) | CLI decisions (P1b) | accepted | 2026-11-06 |
| [0002](0002-guard-dissent-and-suspend.md) | CLI decisions (P3a, `guard`) | accepted | 2026-11-07 |
| [0003](0003-image-cli-contract.md) | CLI decisions (P3b) | accepted | 2026-11-07 |
| [0004](0004-inspect-ntfs-read-only.md) | CLI decisions (P3c, `inspect`) | accepted | 2026-11-07 |
| [0005](0005-copy-ntfs-file-tree.md) | CLI decisions (P3c, `copy`) | accepted | 2026-11-07 |
| [0006](0006-local-snapshot-history.md) | Local snapshot history (P1f, `smart.history`) | accepted | 2026-11-07 |
| [0007](0007-stream-copy-bytes.md) | CLI decisions (P3c, streaming `copy`) | accepted | 2026-11-07 |
| [0008](0008-identity-while-diskarbitration-is-stopped.md) | Identity while DiskArbitration is stopped (P3b follow-up) | accepted | 2026-11-07 |
| [0009](0009-stopped-da-rule-across-the-image-path.md) | The stopped-DA rule reaches the rest of the image path (P3b follow-up) | accepted | 2026-11-07 |
| [0010](0010-mapfile-failed-is-not-bad.md) | Mapfile accounting: failed is not bad (P3b follow-up) | accepted | 2026-11-07 |
| [0011](0011-stop-reason-is-ddrescue-exit.md) | The stop reason is ddrescue's own exit (P3b follow-up) | accepted | 2026-11-07 |
| [0012](0012-check-skips-stopped-diskarbitration.md) | `check` does not wait on a stopped diskarbitrationd (P3 follow-up) | accepted | 2026-11-07 |
| [0013](0013-defer-slow-zones-min-read-rate.md) | Deferring slow zones (`--min-read-rate`, P3b follow-up) | accepted | 2026-11-07 |
| [0014](0014-allocation-aware-ntfs-stage-0.md) | Allocation-aware NTFS stage 0 is a pure library (v3.8) | accepted | 2026-11-07 |
| [0015](0015-allocation-aware-staging-in-image.md) | Allocation-aware NTFS staging is wired into `image` (v3.8) | accepted | 2026-11-07 |
| [0016](0016-stage-0-scope-report.md) | The stage-0 scope report (`image --scope-report`, v3.8) | accepted | 2026-11-07 |
| [0017](0017-test-temp-directories.md) | Test temp directories are removed, and the gate notices when they are not (v3.9) | accepted | 2026-11-07 |
| [0018](0018-scope-report-destination-budget.md) | The scope report's destination needs metadata room, not the device (v3.9) | accepted | 2026-11-07 |
| [0019](0019-unfinished-bitmap-byte-is-unknown.md) | An unfinished `$Bitmap` byte is unknown allocation, never free (v3.9) | accepted | 2026-11-07 |
| [0020](0020-requirement-checks-in-the-gate.md) | Requirement checks run in the gate (v3.9 follow-up) | accepted | 2026-11-07 |
| [0021](0021-first-green-req-gate.md) | First green `req gate` — dispositions for the 40 unlinked claims | accepted | 2026-11-07 |
| [0022](0022-homebrew-packaging.md) | Homebrew tap packaging, keg-relative ntfs-3g, one version | accepted | 2026-11-08 |
| [0023](0023-apache-2-0-licence.md) | Apache-2.0 licence, GPL tools as separate processes | accepted | 2026-11-08 |
| [0024](0024-test-fixture-bootstrap.md) | Test fixtures are built by a tracked bootstrap | accepted | 2026-11-08 |
| [0025](0025-continuous-integration.md) | CI runs on GitHub-hosted macOS, and never claims the gate | accepted | 2026-11-08 |
| [0026](0026-native-read-only-attach.md) | Native read-only attach for APFS, HFS+, exFAT and FAT | accepted | 2026-11-08 |
| [0027](0027-apfs-multi-volume-representation.md) | APFS multi-volume representation and `copy --volume` | accepted | 2026-11-08 |
| [0028](0028-native-attach-leak-guard.md) | The gate fails on a leaked native attach or mountpoint | accepted | 2026-11-08 |
