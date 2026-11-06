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

1. **A `// REQ-NNNN` tag** on the line above the declaration. It is the grep anchor for humans and
   review; a test that proves several claims carries several tags. It is *not* what `req` reads.
2. **The claim's `tests:` list**, holding the exact JUnit id, copied from the report — never
   retyped.

The suite is a regular `.testTarget` using Swift Testing (`import Testing`, `@Test`, `#expect`,
`#require`); `scripts/check.sh` runs it through `swift test --xunit-output` and counts the JUnit
report. What the report actually contains was measured, not assumed:

```
<testcase classname="DiskTriageCoreTests.ExitCodeTests"
          name="precedencePicksTheMostSevere()" time="0.000312083" />
```

- `classname` = `<module>.<suite type name>` → `DiskTriageCoreTests.ExitCodeTests`,
  `DiskTriageCoreTests.SignalSetTests` (the suite type, not the file name, though here they agree).
- `name` = the Swift **function** name plus `()` → `precedencePicksTheMostSevere()`.
- id = `classname::name` →
  `DiskTriageCoreTests.ExitCodeTests::precedencePicksTheMostSevere()`.

**The `@Test("…")` display name does not reach the report.** So the human sentence and the id are
two different strings, and a REQ tag must live in the *function* name to be part of the id:

```swift
// REQ-0038
@Test("precedence picks the most severe: 11 > 10 > 12 > 13 > 20 > 0")
func REQ0038_precedencePicksTheMostSevere() {
    #expect(ExitCode.mostSevere([.mediaRisk, .bridgeLinkPower]) == .mediaRisk, "…")
}
```

```yaml
tests:
  - "DiskTriageCoreTests.ExitCodeTests::REQ0038_precedencePicksTheMostSevere()"
```

A hyphen cannot appear in a Swift identifier, so the tag is `REQ0038_…` in code while the claim id
stays `REQ-0038`. The existing ten tests predate this convention and are unlinked; they keep their
names until a human links them, and renaming a test is a requirement edit either way.

**Parameterised tests collapse.** `@Test(arguments: [1, 2]) func probeParam(_ value: Int)` yields
**one** `<testcase classname="…ProbeParameterisedTests" name="probeParam(_:)">`, not
`probeParam[1]`/`probeParam[2]` as pytest would: a failure in any argument fails the whole case, and
no argument can be linked on its own. If per-case evidence matters, write separate tests.

**The file name is not the one you ask for.** `swift test --xunit-output <dir>/junit.xml` writes
XCTest results to `<dir>/junit.xml` but **Swift Testing results to the sibling
`<dir>/junit-swift-testing.xml`**; with only Swift Testing in the package, `junit.xml` is never
created. The parent directory must already exist — SwiftPM does not create it and the test target
fails with "No such file or directory" — so `scripts/check.sh` creates it, deletes both files
before each run, and counts the union. No XCTest target exists here, so no XCTest shape is recorded;
it would land in the requested file.

**Does `req` consume it? Yes — measured against a scratch corpus** (one claim, `aliases/`, a copy of
the report), not inferred:

| linked id in the report | `req gate --test-report …` |
|---|---|
| a passing test | **0** PASS, `tests_linked` PASS |
| a test the report marks failed | **1** FAIL, `REQ-0001: linked test failed: <id>` |
| an id that was renamed away | **3** UNVERIFIABLE, `REQ-0001: linked test not in the report: <id>` |

So Swift Testing is a usable evidence source for `req`: `classname` is present and non-empty, `name`
is XML-escaped by SwiftPM, and the trailing `()` is accepted verbatim — no name-escaping problem, no
missing `classname`, nothing that needs a `req` change or a Forgejo issue. Two limits are SwiftPM's,
not `req`'s, and are handled in `scripts/`: the report is at a sibling path, and a parameterised test
has no per-argument ids. On the real corpus `req check --test-report
.build/test-results/junit-swift-testing.xml` is still **3** — because all 100 claims are **unlinked**,
not because the report is unreadable.

- **Fixtures:** golden `SignalSet` JSON lives in `Tests/Fixtures/<case>.json` and is replayed by a
  test whose display name begins `REQ-NNNN fixture <case>` (the id keeps the function name, as
  above). Fixtures keep signal *statuses* (denied, timeout), not only values; a fixture with
  history is labelled synthetic.
- **One claim per test where possible.** A shared boundary test may prove several claims; list
  its id in each. A link is a claim about evidence — link only a test that demonstrably proves the
  obligation, and never link on the strength of a numeric constant alone when the claim is about
  the behaviour around it.
- **Renaming a test is a requirement edit:** update every claim that lists the old id in the same
  commit. A stale link is UNVERIFIABLE (exit 3), never a pass.
- A claim with no `tests:` is *no linked test* — UNVERIFIABLE, named per claim. Do not declare
  `evidence: process` to silence it; process evidence is only for obligations a Decision,
  signature or workflow establishes (none of the current 100 claims are process-evidenced).

## `req` in the TDD loop

```
claim (statement + pin)     →  req canon              # parse; 0 flagged pins is authoring green
failing test + // REQ tag   →  bash scripts/check.sh   # red (the project's gate, exit 1)
                            →  .build/test-results/junit-swift-testing.xml
req gate --test-report .build/test-results/junit-swift-testing.xml
                                                       # 1: a linked test failed; 3: link missing/stale
implement                   →  bash scripts/check.sh   # green
req check --test-report .build/test-results/junit-swift-testing.xml
                                                       # 0: every variant and projection confirmed
```

Exit codes are tri-state: **0** settled affirmatively, **1** a definite finding, **3**
UNVERIFIABLE (cannot be told; blocks and is never a pass), **2** usage. `req check` folds one
`req gate` per `.req/variants` line and one `req render --check` per `.req/projections` line;
with neither list it runs one default gate. `req canon` only diagnoses — it never gates a release.

The report is the gate's own evidence too: it is written under `.build/test-results/` (gitignored),
and a missing, empty or zero-testcase report is exit **3** even when the runner exited 0.

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
- The suite runs under Swift Testing and writes a JUnit report that `req` reads (measured above).
  Every claim is nonetheless **unlinked** — deliberately: linking is a human judgement about
  evidence, and this change only made the evidence available. `req check --test-report
  .build/test-results/junit-swift-testing.xml` is therefore exit 3 (*no linked test*), which is
  not a pass. Link a claim when its test's id is copied from a report.
- No `.req/variants` and no `.req/projections` are committed yet; `req check` therefore runs the
  default variant and checks no projection. Add a variant line in the commit that first uses
  `applicability`, and pin `docs/spec.md` only when a projection is a deliverable. Those two
  lists are beside the corpus, not inside `claims/`.
- No signed Baseline: `req baseline --at <ts>` + `minisign` is a human act, and `req audit` stays
  UNVERIFIABLE until it is done.
