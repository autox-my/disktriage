# 0011. The stop reason is ddrescue's own exit (P3b follow-up)

Status: accepted
Date: 2026-11-07

## Context

The same run ended with `STOPPED  ddrescue error` after 996 s although the node
was present, no SIGINT was sent, and ddrescue had been invoked with `-T 90`.
ddrescue stopped itself: `-T` is "maximum time since last successful read", so
a bad region that stalls reads is enough. A generic "error" hid both the code
and the explanation.

## Decision

- **Classification.** A pass the supervisor stops itself is `stop rule`,
  `interrupted` or `device disappeared` as before. A pass that exits on its own
  is `complete` at 0, `interrupted` at 130/143 (the user's Ctrl-C or a SIGTERM
  reached ddrescue directly), and `ddrescue stopped on its own, exit N`
  otherwise. The per-pass stderr line carries the same text and code.
- **Exit codes come from the manual, not a guess.** GNU ddrescue 1.30 documents
  0 normal, 1 environmental problem (file not found, invalid options, I/O
  error), 2 corrupt or invalid input file, 3 internal consistency error. The
  summary's NOTE shows the documented meaning next to the code.
- **`-T` is stated when it is in the command.** `with -T 90 ddrescue stops
  after 90 s without a successful read; the drive may be stalling on a bad
  region; the image is resumable`. JSON adds `stop_exit_code` and
  `stop_detail`; `stopped` is the same sentence the tty prints.

## Consequences

- **Unchanged.** Every non-complete outcome except a launch failure still exits
  **1** and keeps the mapfile; resumability and the printed resume command are
  untouched. `stop rule` is now spelled `pass-2 stop rule`.

## Requirements

None. No claim's `rationale.source` points at this record.
