# Requirements workflow (`req`)

disktriage's requirements are **claims**: one obligation per file in `claims/`, authored by a
human, identified by a content address derived from the statement at load. The plan
(`diskdoctor.md`) is the source; a claim records the obligation, not the plan's prose. `req` reads
`claims/` and `aliases/subjects.yml` (the subject registry) from the repository root.

This page is the project's authoring and traceability convention. The tool's own contracts live on
`req <command> --help`; the adoption path is req's `docs/adopting.md`.

## Add a requirement

1. Take the next free `REQ-NNNN` and create `claims/REQ-NNNN.yml`:

   ```yaml
   schema: req.claim/2
   claim_id: REQ-0042
   statement: "The triage command shall not mount the source volume or write to it, apart from an optional local history snapshot."
   applicability: []
   relations: []
   rationale:
     source: diskdoctor.md#L328
     date: 2026-11-06
     rejected_alternatives: []
     assumptions: []
   pins:
     modality: "SHALL-NOT"
   ```

2. One obligation per claim. One modal phrase (`shall`, `shall not`, `should`); a second
   obligation is a second claim. Avoid `may not` — the tool lints it as ambiguous and leaves the
   claim unstructured.
3. Run `req canon` and read the derived parse. Nothing derived is stored: never add `address`,
   `canonical`, `modality`, `operator`, `value` or `unit` to a claim file — pin them under `pins:`
   instead.
4. Pin what is load-bearing: a numeric bound, its comparator, its unit, or a prohibition's
   modality. Pins use the parser's canonical form — `0.01 percent` parses to `value: "0.0001"`,
   `unit: none`; exit code 10 is `value: "10"`. Exact decimal strings only, never a float and
   never `"0.10"` for `"0.1"`.
5. `applicability` is `[]` until a release variant genuinely differs; `relations: []` means a root
   claim. Both keys are required even when empty.

## Change, split, retire

- **Change:** edit `statement`, then `req canon`. A wording change moves the address; that is
  expected and needs no file rewrite. If the *intent* changed, record the losing option in
  `rationale.rejected_alternatives` and update the linked tests in the same commit.
- **Split:** write the second obligation as a new claim; narrow the first to one obligation. Link
  the new claim to the old with `relations: [{type: "refines", to: "REQ-00NN"}]`.
- **Retire:** delete the claim file deliberately. There is no tombstone, and an empty corpus is
  UNVERIFIABLE (exit 3), not a clean one. Never rename a claim out of the contract
  (`REQ-0008.yml.disabled` is still a claim candidate and fails the corpus); never renumber.
- Do not weaken a statement to make a pin agree — re-word the statement or leave the flag.

## Trace a claim to a test

Two records, with different jobs:

1. **A `// REQ-NNNN` tag** on the line above the test call. It is the grep anchor for humans and
   review; a test that proves several claims carries several tags. It is *not* what `req` reads.
2. **The claim's `tests:` list**, holding the exact JUnit id, copied from the report — never
   retyped.

The suite is the dependency-free runner (`Tests/DiskTriageCoreTests`, TAP-like `ok N - name`),
because this toolchain ships without XCTest and Swift Testing (see `docs/sdlc.md`). The JUnit id
is therefore defined by an adapter that `scripts/` must gain:

- `classname` = `DiskTriageCoreTests.<file stem>`, e.g. `DiskTriageCoreTests.ExitCodeTests`,
  `DiskTriageCoreTests.SignalSetTests`.
- `name` = the test's own name string, verbatim.
- id = `classname::name`, e.g.
  `DiskTriageCoreTests.ExitCodeTests::REQ-0038 precedence picks the most severe code`.

So a new test names its primary claim first, and the tag carries the rest:

```swift
// REQ-0038
test("REQ-0038 precedence picks the most severe code") {
    try expectEqual(ExitCode.mostSevere([.mediaRisk, .bridgeLinkPower]), .mediaRisk, "…")
}
```

```yaml
tests:
  - "DiskTriageCoreTests.ExitCodeTests::REQ-0038 precedence picks the most severe code"
```

- **Fixtures:** golden `SignalSet` JSON lives in `Tests/Fixtures/<case>.json` and is replayed by a
  test whose name begins `REQ-NNNN fixture <case>`. Fixtures keep signal *statuses* (denied,
  timeout), not only values; a fixture with history is labelled synthetic.
- **One claim per test where possible.** A shared boundary test may prove several claims; list
  its id in each. A link is a claim about evidence — link only a test that demonstrably proves the
  obligation, and never link on the strength of a numeric constant alone when the claim is about
  the behaviour around it.
- **Renaming a test is a requirement edit:** update every claim that lists the old id in the same
  commit. A stale link is UNVERIFIABLE (exit 3), never a pass.
- A claim with no `tests:` is *no linked test* — UNVERIFIABLE, named per claim. Do not declare
  `evidence: process` to silence it; process evidence is only for obligations a Decision,
  signature or workflow establishes (none of the current 100 claims are process-evidenced).
- If the suite ever moves to XCTest or Swift Testing, the convention survives: `// REQ-NNNN` above
  the declaration, `classname` = `<module>.<class>` (XCTest) or the suite's type name (Swift
  Testing), `name` = the function name.

## `req` in the TDD loop

```
claim (statement + pin)     →  req canon              # parse; 0 flagged pins is authoring green
failing test + // REQ tag   →  bash scripts/check.sh   # red (the project's gate, exit 1)
                            →  JUnit report
req gate --test-report <junit.xml>                    # 1: a linked test failed; 3: link missing/stale
implement                   →  bash scripts/check.sh   # green
req check --test-report <junit.xml>                    # 0: every variant and projection confirmed
```

Exit codes are tri-state: **0** settled affirmatively, **1** a definite finding, **3**
UNVERIFIABLE (cannot be told; blocks and is never a pass), **2** usage. `req check` folds one
`req gate` per `.req/variants` line and one `req render --check` per `.req/projections` line;
with neither list it runs one default gate. `req canon` only diagnoses — it never gates a release.

The missing link is the TAP→JUnit adapter above: `scripts/check.sh` reads the runner's
`Executed N tests` summary, but nothing writes a JUnit document. Until the adapter exists, no
claim may be linked (the id would be a guess) and `req gate`/`req check` answer exit 3 for every
claim — truthfully. The adapter is `scripts/` work, with a probe that proves it bites.

## Deliberately not claims (plan §9)

These are open decisions or P0 verification tasks, not obligations; they are tracked in
`diskdoctor.md`, not in `claims/`.

| Item | Why not a claim |
|---|---|
| Implementation language | Open in the plan; `Package.swift` chooses Swift outside the corpus |
| FDA process identity (Terminal vs app vs helper) | P0 result decides; the claims encode only degraded mode and the broad-grant warning |
| Final product name | Decided 2026-11-06: `disktriage` (plan §13); `DISKTRIAGE` is a corpus-local subject id, not the bundle name |
| Per-file damage attribution | v1 is volume-level (claimed); the NTFS runlist parser is a v1.1 plan, not an obligation |
| Keep `copy`? | Open until P3; if cut, delete `REQ-0092`–`REQ-0095` and the §8 copy rule deliberately |

P0 questions (`SMART` over USB, I/O counters, log retention, `F_LOG2PHYS_EXT`, dissent vs
third-party mounts, ddrescue semantics, TCC errno, internal-disk probe) are verification gates.
Two claims state their P0 dependency explicitly: `REQ-0029` (I/O statistics are displayed but not
counted until P0 validates them) and `REQ-0063` (the probe reads the internal disk, falling back
only if that is impossible).

## Current state

- 100 claims, all structured, 51 pins held, 0 lints (`req canon --fail-on-flag` → 0).
- Every claim is machine-evidenced and **unlinked** — deliberately: no JUnit report exists, so
  `req check` is exit 3 (UNVERIFIABLE) and that is not a pass. Link a claim when its test's id
  first appears in a report the adapter wrote.
- No `.req/variants` and no `.req/projections` are committed yet; `req check` therefore runs the
  default variant and checks no projection. Add a variant line in the commit that first uses
  `applicability`, and pin `docs/spec.md` only when a projection is a deliverable. Those two
  lists are beside the corpus, not inside `claims/`.
- No signed Baseline: `req baseline --at <ts>` + `minisign` is a human act, and `req audit` stays
  UNVERIFIABLE until it is done.
