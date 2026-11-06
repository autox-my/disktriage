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

The gate runs `swift build`, then `swift test --xunit-output .build/test-results/junit.xml`,
prints both logs in full, and chooses one outcome from the JUnit report it counts.

### Commands

| What | Command |
|---|---|
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

### CLI decisions (P1b)

- `disktriage triage --from <signalset.json>` is the only working command; live
  collection arrives with the collectors in P2. Without `--from` it says so on
  stderr and exits **30** (tool error). `image`, `inspect`, `copy`, `check` and
  `list` also exit 30 with "not implemented yet (planned P2/P3)".
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

### CLI decisions (P3a, `guard`)

`disktriage guard [--suspend] [--seconds N] [--json] [--observe]` is the mount
guard from diskdoctor.md §8. It is streamed, not buffered: a decision line is
written and flushed when it is made, because a guard runs for minutes.

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
- The suite never sends a signal: `ProcessSignaling` is injected and faked. The
  DiskArbitration shim is exercised for real only by the unprivileged
  `--seconds 5` smoke with no disk attached.

### CLI decisions (P3b)

- `image --no-dry-run` exits **0** when both passes finish, **1** when it
  stopped by the pass-2 rule, a device disappearance, an interrupt or a
  ddrescue error (all resumable), and **30** for a precondition/tool error.
  These are deliberately not the verdict codes.
- A missing `--accept-risk` is a **usage error (2)**: it is a flag, not an
  environment fact. Root, FDA, the mount guard, ddrescue and the dry-run
  checks exit **30**.
- FDA `UNKNOWN` blocks imaging as well as `DENIED`: an unverified grant is not
  a pass (plan §7), even though the brief only named `DENIED`.
- The resume command printed on an incomplete image is the
  `disktriage image ... --no-dry-run` command, not the raw ddrescue line:
  ddrescue resumes from the mapfile, and the wrapper re-runs the same
  preconditions.
- The sidecar (`<image>.disktriage.json`) is rewritten at each run start
  (`created_at` is this attempt) and records both pass argv; the device
  identity fields remain the resume authority.
- "Complete" means both passes exited 0. Bad sectors can remain (`-` extents);
  they are reported as bad bytes and are zero-filled in the image, not treated
  as an incomplete run.

### The test report is the evidence

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
  `<testcase>` and exits 0. A report carrying a `<failure>`, `<error>` or
  `<skipped>` case is exit **1**: a skipped test is not a pass.
- The report lives under `.build/`, which is gitignored; no artefact is added to
  the repository.

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
7. **Keep the requirement link in step with the report (advisory).** After
   the suite writes `.build/test-results/junit-swift-testing.xml`, run
   `./scripts/req-link.sh --check`: **0** the claims' `tests:` lists match the
   `REQ` tags in the report, **1** drift, **3** the report is missing, empty or
   unparsable. `./scripts/req-link.sh` writes the lists from the tags. This is
   deliberately not part of `scripts/check.sh` — the gate does not depend on
   `req` — so drift is a finding to fix, not a gate failure.

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
