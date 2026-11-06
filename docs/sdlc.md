# The disktriage SDLC — solo human, agents, one gate

`diskdoctor.md` is the plan and the source of scope. This file is how a change
gets made: the loop, the gate's contract, and what "done" means. It is short on
purpose; the enforcement is `scripts/check.sh`, not this prose.

## The gate

```bash
bash scripts/check.sh        # 0 PASS · 1 FAIL · 3 UNVERIFIABLE
```

| Exit | Meaning | What you do |
|---|---|---|
| **0** | PASS | proceed |
| **1** | FAIL | fix it; it is yours |
| **3** | UNVERIFIABLE / SKIP | **stop and report.** Never edit the gate, a fixture or an expectation to turn grey into green. |

- A skipped check is never a pass. Neither is a runner that exits 0 without
  executing a test: `check.sh` reports **3** for zero executed tests.
- Never read an exit status through a pipeline. `cmd | tail` reports `tail`'s
  status. Capture `$?` on the command itself.
- Never relax the gate to land a change. A wrong check is a separate change
  with its own evidence.
- Grey is a finding, not a bug. Report what could not run and why.

The gate runs `swift build` and then the test suite, prints both logs in full,
and chooses one outcome. `DISKTRIAGE_BUILD_SYSTEM` exists only for a deliberate
toolchain experiment.

### Commands

| What | Command |
|---|---|
| The gate | `bash scripts/check.sh` |
| Build | `swift build --build-system native` |
| Tests | `swift run --build-system native DiskTriageCoreTests` |
| CLI (skeleton; P1 adds commands) | `swift run --build-system native disktriage` |

The `native` engine is pinned because the default `swiftbuild` engine cannot
initialise on this machine (CLT-only toolchain, "Unknown error parsing property
list"). The test runner is a dependency-free executable because this toolchain
ships without XCTest and without Swift Testing; `swift test` takes over the day
a framework is available. Both facts are recorded in `Package.swift` and here
so nobody "fixes" the gate by deleting it.

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

One change = one small diff. Red, green and refactor are commit-sized units,
not one giant commit at the end.

## Fixtures

Golden `SignalSet` JSON lives in `Tests/Fixtures/` and is replayed against the
core. A fixture is code: it is reviewed like code.

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
      hand-back (not a piped status).
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
