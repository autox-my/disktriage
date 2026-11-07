# 0002. CLI decisions (P3a, `guard`)

Status: accepted
Date: 2026-11-07

## Context

`disktriage guard [--suspend] [--seconds N] [--json] [--observe]` is the mount
guard from diskdoctor.md §8. It is streamed, not buffered: a decision line is
written and flushed when it is made, because a guard runs for minutes. The plan
has no other way to ask for an observation that exits 0 without root.

## Decision

- **It never claims protection that is not active.** The first line is
  `mode=dissent|suspend protection: ACTIVE` or
  `protection: NOT ACTIVE (reason)`. Without root the dissent is not honoured,
  so it says `NOT ACTIVE (not root)` and never `ACTIVE`.
- **Exit 0**: the run completed — a dissent run as root, an observation, or a
  suspend whose teardown resumed or correctly held. SIGINT/SIGTERM runs teardown
  and exits 0, so an interrupt is not a crash.
- **Exit 30**: protection was requested and is not active (not root with no
  `--seconds` bound, or any `--suspend` without root), a suspend did not reach
  `ps -o stat=` state `T`, or the daemon could not be resumed.
- **Exit 2**: usage (unknown option, bad `--seconds`, `--observe` without
  `--seconds` or with `--suspend`).
- `--observe` is the explicit observation-only run that exits 0 without root; it
  requires `--seconds`. Without root, the default `--seconds N` run still
  observes and logs, then exits 30 because protection was requested. The
  `--observe` flag is additive to the plan's synopsis, which has no other way to
  ask for an observation that exits 0.
- **Suspend teardown is the safety-critical rule**: SIGCONT is sent only when no
  new `/dev/rdisk*` node appeared since start (compare sets, not counts). If a
  node is still present the daemon stays suspended and the last line is
  `unplug the disk, then run: sudo kill -CONT <pid>`.
- `--json` writes one JSON object per decision and a final summary on stdout;
  the human banner, the honesty line and the warning stay on stderr.

## Consequences

- The suite never sends a signal: `ProcessSignaling` is injected and faked. The
  DiskArbitration shim is exercised for real only by the unprivileged
  `--seconds 5` smoke with no disk attached.
- An interrupt is a completed run, not a crash, and a failed teardown leaves
  the daemon suspended only with the explicit `kill -CONT` instruction printed.

## Requirements

None. No claim's `rationale.source` points at this record.
