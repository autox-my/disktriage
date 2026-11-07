# 0001. CLI decisions (P1b)

Status: accepted
Date: 2026-11-06

## Context

At P1b the CLI has one job: classify a recorded `SignalSet`. Live collection
arrives with the collectors in P2. The plan is silent on a usage code and on
what a recorded set can suggest as an image destination.

## Decision

- `disktriage triage --from <signalset.json>` classifies a recorded set; live
  collection arrives with the collectors in P2. Without `--from` it says so on
  stderr and exits **30** (tool error). At P1b, `image`, `inspect`, `copy`,
  `check` and `list` also exited 30 with "not implemented yet (planned
  P2/P3)"; `inspect` is implemented in P3c and `copy` in P3c (below). No
  planned command remains.
- **Usage errors exit 2** (unknown command, unknown flag, `--from` without a
  value). The plan is silent on a usage code, so this page records the choice:
  it is req's convention and collides with no verdict or collection code
  (0, 10–13, 20, 21, 30).
- `--help` and `<command> --help` exit 0 on stdout and read nothing.
- A recorded set has no live device, so the suggested image destination is
  derived from the file stem (`<stem>.img` under `/Volumes/Scratch`). That is
  what reproduces the Appendix transcript, which carries
  `--to /Volumes/Scratch/minah.img` that `triage --from` cannot supply.
- `--json` prints the same verdict as the tty on stdout; progress stays on
  stderr. `--local` renders log timestamps in the local zone (default UTC).

## Consequences

The recorded-set path stays offline and deterministic: it derives the image
destination from the file stem and only changes rendering with `--json` and
`--local`, so it reproduces the Appendix transcript without a live device. The
usage code 2 is separate from every verdict and collection code.

## Requirements

None. No claim's `rationale.source` points at this record.
