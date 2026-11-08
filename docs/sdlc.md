# The disktriage SDLC — solo human, agents, one gate

`diskdoctor.md` is the plan and the source of scope. This file is how a change
gets made: the loop, the gate's contract, and what "done" means. It is short on
purpose; the enforcement is `scripts/check.sh`, not this prose. Decisions that
changed a contract are records in [`docs/adr/`](./adr/), not prose appended
here.

## The gate

```bash
bash scripts/check.sh        # 0 PASS · 1 FAIL · 3 UNVERIFIABLE
```

| Exit | Meaning | What you do |
|---|---|---|
| **0** | PASS | proceed |
| **1** | FAIL | fix it; it is yours |
| **3** | UNVERIFIABLE / SKIP | **stop and report.** Never edit the gate, a fixture or an expectation to turn grey into green. |

- A skipped check is never a pass: `check.sh` reports **3** (UNVERIFIABLE) and
  names the skipped tests, not 1. A real failure is **1**, even beside a skip.
  Neither is a runner that exits 0 without executing a test: `check.sh` reports
  **3** for zero executed tests.
- Never read an exit status through a pipeline. `cmd | tail` reports `tail`'s
  status. Capture `$?` on the command itself.
- Never relax the gate to land a change. A wrong check is a separate change
  with its own evidence.
- Grey is a finding, not a bug. Report what could not run and why.

The gate runs `swift build`, then `swift test --xunit-output .build/test-results/junit.xml`,
prints both logs in full, and chooses one outcome from the JUnit report it counts.

### Commands

| What | Command |
|---|---|
| Test fixtures (one command) | `scripts/bootstrap.sh` |
| The gate | `bash scripts/check.sh` |
| Build | `swift build` |
| Tests | `swift test` |
| Tests with the report the gate reads | `swift test --xunit-output .build/test-results/junit.xml` |
| CLI (triage a recorded SignalSet) | `swift run disktriage triage --from Tests/Fixtures/minah.json` |

The toolchain is full Xcode 27.2 / Swift 6.4.2, so the two old workarounds are
retired — but only because they were measured unnecessary, not because they
were inconvenient:

- **Default build engine.** `swift build` and `swift test` succeed with the
  default `swiftbuild` engine under this toolchain. The old "Unknown error
  parsing property list" failure belonged to the Command Line Tools-only
  install; it does not reproduce here, and the `native` pin (now deprecated by
  SwiftPM) is gone.
- **Swift Testing.** The suite is a regular `.testTarget` using `import
  Testing` (`@Test`, `#expect`, `#require`). The dependency-free runner and its
  `Support.swift` were deleted only after the migrated suite was observed green
  with the same ten tests and names, and mutation-checked: inverting the 11/10
  precedence, then the 11/12 precedence, turned it red; restoring them turned
  it green. If `import Testing` ever stops resolving, the build fails and the
  gate answers **1** — never a silent run of nothing.

### The report the gate counts

`scripts/check.sh` reads a JUnit report, not the runner's prose:

- `swift test --xunit-output <dir>/junit.xml` writes **XCTest** results to
  `<dir>/junit.xml` and **Swift Testing** results to
  `<dir>/junit-swift-testing.xml`, a sibling file. No stale report may answer
  for a run, so both are deleted before the runner starts; the gate counts the
  union and prints only the files that were actually written.
- The parent directory must exist: SwiftPM does not create it, and a missing
  directory fails the test target ("No such file or directory"). The gate
  creates it.
- A missing, empty, unparsable or **zero-testcase** report is exit **3**, even
  when the runner exited 0 — a filtered or empty run writes a report with no
  `<testcase>` and exits 0. A report carrying a `<failure>` or `<error>` case is
  exit **1**. A `<skipped>` case is exit **3**, and the gate names the skipped
  tests: a skip is UNVERIFIABLE, never a pass and never a failure. A failure
  beside a skip is still **1**.
- The counting and the verdict live in `scripts/lib/junit-report.sh`, shared
  with `scripts/check-gate-probe.sh`, which proves 0/1/3 from faked reports.
- The report lives under `.build/`, which is gitignored; no artefact is added to
  the repository.

After the suite, the gate also runs five read-only requirement steps —
`req canon`, `scripts/req-link.sh --check`, `req gate`,
`scripts/req-anchors.sh --check` and `scripts/req-counts.sh --check` — and folds
them into the same three answers; ADR
[0020](./adr/0020-requirement-checks-in-the-gate.md) records that decision.

## The TDD loop (mandatory for code)

1. **Name the seam before writing the test.** The public type, function or CLI
   exit code the test drives. If you cannot name it, the design is not ready.
2. **Write the failing test first.** Run it and watch it fail for the right
   reason — missing behaviour, not a typo or an import. A test that never
   failed has tested nothing.
3. **Write only enough code to pass**, then **refactor** with the suite green.
4. **Keep expectations independent of the implementation.** Values come from
   `diskdoctor.md`, the recorded fixture, or a hand-computed count — never
   recomputed the way the code computes them.
5. **Mutation-check the load-bearing rule.** Break the rule the test protects
   (e.g. invert the exit-code order) and confirm the test goes red. Restore it
   and confirm green. A rule removable without a failing test was never covered.
6. **Fixture and expectation move together**, in the same commit, with the
   reason stated. A re-baselined expectation with no reason is a defect.
7. **Keep the requirement link in step with the report.** After the suite
   writes `.build/test-results/junit-swift-testing.xml`, run
   `./scripts/req-link.sh --check`: **0** the claims' `tests:` lists match the
   `REQ` tags in the report, **1** drift, **3** the report is missing, empty or
   unparsable. `./scripts/req-link.sh` writes the lists from the tags;
   `--check` is a read-only `scripts/check.sh` step (ADR
   [0020](./adr/0020-requirement-checks-in-the-gate.md)), and the write mode
   that edits the corpus is deliberately not in the gate, which never rewrites
   a claim.

One change = one small diff. Red, green and refactor are commit-sized units,
not one giant commit at the end.

## Fixtures

Golden `SignalSet` JSON lives in `Tests/Fixtures/` and is replayed against the
core. A fixture is code: it is reviewed like code.

The live NTFS tests need a built ntfs-3g prefix and synthetic images, which are
64–80 MiB each and cannot be committed. `scripts/bootstrap.sh` is the one
documented setup command: it builds the pinned ntfs-3g tools into
`.build/ntfs-prefix` and generates the images under `.build/fixtures/ntfs` from
the tracked generator in `tools/ntfs-fixture/`. `Tests/TestSupport` locates them
through `DISKTRIAGE_NTFS_PREFIX` / `DISKTRIAGE_FIXTURE_DIR`, then `.build/`;
`captures/` is never a test input. When the bootstrap output is absent the gate
is **3** and names the command (ADR
[0024](./adr/0024-test-fixture-bootstrap.md)).

- Every collected section carries a `status`; include `denied`, `timeout` and
  `unsupported` fixtures, not only happy values.
- A counter that is unknown is `null`, never `0`. "Absent is never zero."
- **MiNaH** is the real case and the first sight of that drive: `history` is
  `null`. Never invent a snapshot to make a trend rule fire; synthetic history
  is labelled synthetic in the fixture and in the test name.
- Real captures carry serials, so only redacted captures may be committed
  (`*.img`, `*.mapfile` and `captures/` are gitignored).

## Definition of done

- [ ] `bash scripts/check.sh` exits **0**, and the real code is quoted in the
      hand-back (not a piped status). The PASS line names the test count the
      JUnit report carried, not the runner's own claim.
- [ ] New behaviour had a test that failed first, for the right reason.
- [ ] The load-bearing rule was mutation-checked (red, then restored green).
- [ ] Fixture and expectation changed together, with the reason in the commit.
- [ ] No absent signal became a zero; unknown stays `null` plus a status.
- [ ] `DiskTriageCore` contains no OS calls, no subprocesses, no filesystem reads.
- [ ] Scope came from `diskdoctor.md`; no feature was invented in passing.
- [ ] Docs updated in the same change if a rule or contract changed.
- [ ] Commit uses a conventional prefix, files were staged by name, no secrets.

## Commits and review

Conventional prefixes: `feat:` `fix:` `refactor:` `test:` `docs:` `chore:`.
Stage files by name (`git add <paths>`); never `git add -A`, never
`git commit --no-verify`, never change the git identity or pass
`-c user.name=…`. The human merges. When the brief says the human commits, the
agent stops at a green gate and stages nothing.

Requirement traceability for this repo: [`docs/req-workflow.md`](./req-workflow.md).

## Decisions

Architecture decisions live in [`docs/adr/`](./adr/); the index is
[`docs/adr/README.md`](./adr/README.md). Each file records one decision area,
its context, the decision and its consequences, and the claims that cite it.

- A new decision is a **new ADR file** (`docs/adr/NNNN-short-slug.md`, next
  number). Never append a decision to this page.
- Write an ADR when a decision changes a contract others can observe — a CLI
  flag or exit code, a JSON or manifest key, a sidecar field, a file format, a
  retention or permission rule, a safety rule, or the gate's own verdict rule —
  or when a future reader would otherwise have to reverse-engineer it from the
  code or a transcript. Implementation details that merely follow
  `diskdoctor.md` do not need one.
- A decision that genuinely replaces an earlier one is a new ADR with the next
  number; the old record's `Status:` becomes `superseded by NNNN`. Do not
  rewrite an accepted record to agree with later code.
- A claim cites an ADR as
  `docs/adr/NNNN-short-slug.md#<heading-slug>`; `scripts/req-anchors.sh
  --check` must resolve it.
