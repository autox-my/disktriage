# AGENTS.md — DiskDoctor

DiskDoctor triages a failing disk from hardware signals, images it, and hands
off. The plan is [`diskdoctor.md`](diskdoctor.md) (v3) and is the only source of
scope; the SDLC is [`docs/sdlc.md`](docs/sdlc.md); vocabulary is
[`CONTEXT.md`](CONTEXT.md). Where this file and `scripts/check.sh` disagree, the
gate wins and the disagreement is a finding.

`DiskDoctorCore` is a pure, portable library: no OS calls, no subprocesses, no
filesystem access. Collectors and the CLI live outside it. The classifier is a
pure function over a `SignalSet`; everything else is plumbing.

## Commands

| What | Command |
|---|---|
| The gate — run before handing back | `bash scripts/check.sh` |
| Build | `swift build --build-system native` |
| Tests | `swift run --build-system native DiskDoctorCoreTests` |
| CLI (skeleton; commands land in P1) | `swift run --build-system native diskdoctor` |

**Never read an exit status through a pipeline.** `cmd | tail` reports `tail`'s
status. Capture `$?` on the command itself.

This toolchain ships without XCTest and without Swift Testing, so the suite is a
dependency-free executable and the default `swiftbuild` engine is replaced by
`native`. Do not delete either workaround to "simplify"; see `docs/sdlc.md`.

## The gate's three answers — the third is not a pass

| Exit | Meaning | What you do |
|---|---|---|
| **0** | PASS | proceed |
| **1** | FAIL | fix it; it is yours |
| **3** | UNVERIFIABLE / SKIP | **stop and report.** Do not edit the gate, fixtures or expectations to turn grey into green. |

A skipped check is never a pass, and neither is a runner that executes zero
tests. Never `git commit --no-verify`. Never relax a gate to land a change.

## TDD is mandatory for code

1. Name the public seam the test will drive before writing it.
2. Write the failing test first; watch it fail for the right reason.
3. Only enough code to pass, then refactor with the suite green.
4. Expectations come from `diskdoctor.md` or a recorded fixture — never
   recomputed the way the code computes them.
5. Mutation-check the load-bearing rule: break it, see red, restore, see green.
6. Fixture and expectation move together, same commit, with the reason stated.

Docs and schemas are verified by the gate and review, not by TDD. A fixture is
code, and so is the check that reads it.

## Correctness rules

- **An absent signal is never a zero.** Every collected section has a `status`
  (`ok | denied | unsupported | timeout | error`); counters are `null` when
  unknown. `denied`, `timeout` and `unsupported` are not measurements.
- **Never mount the source device.** Triage reads hardware signals only;
  inspection happens on the image. `guard` exists because the OS automounts.
- **Insufficient evidence is a verdict** (exit 20). Never infer health from a
  missing signal; "healthy" is not a verdict this tool can issue.
- **Exit-code precedence** when several findings apply:
  `11 > 10 > 12 > 13 > 20 > 0`. 21 and 30 are returned only when no verdict can
  be formed; otherwise they are signal statuses.
- **No invented history.** `smart.history` is `null` on first sight; trend rules
  never fire without a real prior snapshot, and fixtures never invent one.
- **Never destroy evidence.** Reads only until the user explicitly asks for a
  write, and writes only target an image or a copy destination.
- **The tool must not hang with the disk.** Every collector needs a hard timeout
  and a process-group kill; a timeout is evidence, not a crash.

## How to work

- Conventional commit prefixes: `feat:` `fix:` `refactor:` `test:` `docs:`
  `chore:`. Stage files by name; never `git add -A`; no secrets.
- Never change the git identity or pass `-c user.name=` / `-c user.email=`.
  Commits are the human's unless the brief says otherwise; the human merges.
- Report findings; do not widen scope. A new feature starts as a change to
  `diskdoctor.md`, not as code in passing.
- Keep `DiskDoctorCore` free of OS assumptions so Linux can be a collector, not
  a rewrite.

## Where things live

| Path | What it is | May an agent write? |
|---|---|---|
| `diskdoctor.md` | the plan, v3 — scope and phase gates | only when the brief says so |
| `docs/` | SDLC and requirement workflow | yes |
| `Sources/DiskDoctorCore/` | `SignalSet`, `Verdict`, exit codes — pure | yes, test first |
| `Sources/diskdoctor/` | thin CLI target | yes, test first |
| `Tests/DiskDoctorCoreTests/` | the dependency-free suite | yes, test first |
| `Tests/Fixtures/` | golden `SignalSet` JSON (redacted only) | yes, with the test |
| `scripts/` | the gate | yes, with a probe that proves it bites |
