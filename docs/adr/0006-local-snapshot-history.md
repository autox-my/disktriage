# 0006. Local snapshot history (P1f, `smart.history`)

Status: accepted
Date: 2026-11-07

## Context

`triage` keeps a small local store so the trend rule (`reallocated` rising vs a
prior snapshot -> MEDIA, exit 10) can fire on a real prior reading. It is the
one write triage can make, and the plan calls it optional (diskdoctor.md §4,
§6).

## Decision

- **Location.** `~/Library/Application Support/disktriage/history/`, overridden
  by `DISKTRIAGE_HISTORY_DIR` and then by `--history-dir <path>` (the flag wins).
  The flag exists for tests and portability; the environment variable is the
  documented non-CLI override.
- **Layout and why.** One directory per device, one JSON file per snapshot:
  `history/<full-sha256>/<epoch-ms>-<uuid>.json`. A directory per key makes the
  per-device cap and the foreign-device check trivial. One file per snapshot is
  the crash-safe choice: it is written to a temp file in the same directory and
  atomically renamed, so an interrupted write leaves either no snapshot or a
  complete one. An append-only JSONL would leave a half-line that every later
  read must special-case; here a half-written file simply fails to decode and is
  skipped with a note.
- **Identity.** The key is the **full** SHA-256 (64 lowercase hex characters) of
  the raw serial — never truncated, never `diskN`, and the raw serial is never
  written to a path or a file. A device with no serial has no key, so there is no
  history read, no snapshot write, and the run says
  `history: unavailable (no serial; ...)`.
- **Record.** `schema_version`, `recorded_at` (UTC ISO-8601), `device_key`, the
  SMART section `status` it was taken under, and nullable `pending`,
  `reallocated`, `uncorrectable`. Only a record with `smart_status: ok` is a
  measurement: the store refuses to write any other status, and a hand-placed
  non-ok record yields no history (never zeros). The newest prior record is the
  only one considered; falling back to an older `ok` record would invent a trend
  across a gap.
- **Retention and permissions.** At most the newest **50** snapshots per device;
  older ones are trimmed on write. The history and per-device directories are
  `0700`, every snapshot file `0600`.
- **Damage tolerance.** A corrupt file, an unknown schema version, a
  foreign-device key or a non-snapshot file is skipped with a note on stderr; it
  never crashes and never becomes a number in the verdict.
- **Live only.** `--from <signalset.json>` never reads or writes the store. The
  live path reads the prior snapshot before classifying, attaches it to
  `smart.history`, classifies, and writes the new snapshot after unless
  `--no-history` is given. `image`'s internal triage attempt is read-only too:
  it does not read or write history (the plan's read-only side-effect rule).

## Consequences

- **Failure is a note, not a verdict.** A failed snapshot write is printed on
  stderr and leaves the verdict and exit code exactly as the classifier chose
  (REQ-0160). The same holds on this Mac's USB drives: SMART is unreadable there,
  so the run reports `history: unavailable (SMART unsupported is not a
  measurement; ...)` and writes nothing — absent is never a zero.

## Requirements

- REQ-0150
- REQ-0155
