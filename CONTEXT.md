# CONTEXT.md — DiskDoctor glossary

Vocabulary only. Rules live in `AGENTS.md` and `docs/sdlc.md`; scope lives in
`diskdoctor.md`.

**Device** — the physical drive under triage, identified by model, serial and
size — never by `diskN` alone, because the BSD name changes on reconnect.

**SignalSet** — the versioned JSON contract between collectors and the
classifier: one section per signal family, each with a status, counters nullable.

**Signal status** — how a section's evidence was obtained: `ok`, `denied`,
`unsupported`, `timeout` or `error`. Only `ok` makes a counter a measurement.

**Cause** — a root-cause hypothesis in a verdict (`MEDIA`, `HEAD`, `LINK`,
`POWER`, `BRIDGE`, `FILESYSTEM`, `UNKNOWN`), carrying confidence and the
evidence for it.

**Aggravator** — a condition that modifies the advice without being the root
cause (`DRIVER`, `SMR`, `ENCRYPTED`).

**Verdict** — the reportable outcome: the chosen exit code plus a one-line
headline. Causes and aggravators stay listed separately.

**Differential** — the ranked list of causes with evidence, what would falsify
each, and the single cheapest next test. Not a health score.

**Image** — a byte-for-byte copy of a device, the only thing inspected and
mounted. Unreadable regions are zero-filled, so they are not I/O errors.

**Mapfile** — ddrescue's record of which image extents were read, retried or
never recovered; the authority on which bytes are real.

**Triage** — the read-only, no-mount pass over hardware signals that produces a
verdict and the next action.

**FDA** — Full Disk Access: the macOS TCC permission that gates raw block
devices. Required for imaging, not for diagnosis; never cached across launches.

**Fixture** — a recorded `SignalSet` JSON replayed against the classifier in
tests; a test input, not a schema and not a live capture.

**Mount guard** — the process that holds DiskArbitration mounts for a target
device, so the OS cannot automount a failing disk before triage.
