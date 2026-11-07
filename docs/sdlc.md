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
  stderr and exits **30** (tool error). At P1b, `image`, `inspect`, `copy`,
  `check` and `list` also exited 30 with "not implemented yet (planned
  P2/P3)"; `inspect` is implemented in P3c (below) and only `copy` remains a
  planned command.
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
- **`image --limit <GiB>` is partial imaging.** The value is a positive whole
  number of GiB (2^30 bytes); zero, a fraction, a negative number, a non-number
  or a missing value is a **usage error (2)**. A limit at or above the device
  size is the full device, so it is not labelled partial and carries no `-s`.
  When partial, both ddrescue passes get `-s <bytes>`; the human plan and the
  JSON plan say `PARTIAL (N GiB of M GiB)`; the free-space gate checks the
  limit while still naming the whole device; and the ETA is for the limit.
- The **size confirmation is still the whole device** (`--confirm-size <GiB>` or
  the serial's last four), never the limit: the limit is how much is read, not
  which disk it is.
- The sidecar records `limit_bytes` (absent for a full image). It is part of the
  resume authority: a different limit, or a full-versus-partial change, is
  refused with **exit 30** and a message naming both the recorded and requested
  extent, before any read.
- A partial run that finishes is reported as **`partial image complete (first N
  GiB)`** in the human summary and in JSON (`status` and `stopped`), never as a
  complete image of the device. The exit codes are unchanged: 0 complete, 1
  incomplete-resumable, 30 precondition. The pass-2 stop rule's 0.01% threshold
  and remaining-time projection use the limited size.
- The limit is whole GiB on the CLI. The byte value is injectable at
  `image(..., limitBytesOverride:)`, the seam the tests use for a sub-GiB file
  smoke; no fractional CLI flag exists.
- **Mapfile accounting for a partial image is clamped to `[0, limit)`.** GNU
  ddrescue 1.30 with `-s` leaves the untried tail ending at `Int64.max`
  (`0x7FFFFFFFFFFFFFFF`), so an unclamped mapfile reports ~8.6 billion GiB
  remaining. Every extent is clipped to the range, an extent starting at or
  after the limit is dropped, and `rescued`, `bad`, `remaining`, the extent
  count and the percentage are computed inside it (`remaining = limit - rescued
  - bad`). A full image keeps the mapfile's own extents exactly as before. The
  pass-2 stop rule and the complete/incomplete decision use the limited size,
  clamped numbers and ddrescue's exit code — never the unbounded tail.

### CLI decisions (P3c, `inspect`)

`disktriage inspect <image> [--mapfile <path>] [--json]
[--restore-boot-sector --to <working-copy>]` is the read-only NTFS inspection
from diskdoctor.md §6 and §8. v1 is **NTFS only**; the other filesystems the
plan names are detected and refused, not attached (a plan gap, below).

- **Exit codes.** `0` inspected and no damage note; `1` inspected but the
  mapfile reports damage or the volume only partly opened; `30` a precondition
  or tool error (missing image, ntfs-3g tools absent, volume cannot be opened).
  The verdict codes 10–13, 20 and 21 are not inspect's, and it never returns
  them. `/dev/*` is refused with the usage code **2** before any read.
- **Images only.** A device path and a non-regular file are refused. The only
  writes inspect can make are to an explicitly requested `--to` working copy
  (boot-sector restore); the source image is opened read-only everywhere else.
- **Tools.** `DISKTRIAGE_NTFS_PREFIX` (a built tree with `bin/ntfsinfo` and
  `bin/ntfsls`; `sbin` too for the test's `mkntfs`), then PATH, then the usual
  Homebrew/system directories. Missing tools exit **30** with the prefix hint;
  there is no mount fallback. Every call goes through `ProcessRunner` with the
  `inspect` allow-list (`ntfsinfo -m`, `ntfsls -l`, `ntfsls -R`), a hard
  timeout and a process-group kill: 30 s for `ntfsinfo` and the root listing,
  120 s for the recursive listing. `ntfsfix`, `-f/--force`, a writer and a
  `/dev/*` path are rejected before `exec`.
- **Layout.** A whole-disk image is recognised by a non-empty MBR, or a
  protective MBR plus a GPT header and entry array (the parser is pure in
  `DiskTriageCore`; 512-byte LBAs are assumed). The NTFS partition is the first
  0x07 candidate (MBR) or Microsoft basic-data GUID (GPT) whose boot sector has
  the NTFS OEM ID. A 0x07/basic-data partition whose boot sector is missing is
  still kept as a candidate so boot-sector damage can be reported or restored.
  The partition is extracted to a temporary file (`dd skip=/count=` semantics,
  bounded chunks) because the tools have no offset option; cluster numbers stay
  volume-relative. A bare NTFS volume is read directly.
- **Output.** `--json` is the same report as the tty, with stable keys and a
  status (`ok | denied | unsupported | timeout | error`) per section. Sections
  are `layout`, `filesystem`, `tools`, `boot_sector`, `volume`, `listing` and
  `damage`. Unknown counters are omitted, never `0`.
- **Mapfile.** `--mapfile` wins; otherwise `<image>.mapfile` is used when it
  exists. The sidecar `<image>.disktriage.json`'s `limit_bytes`, when present,
  clamps the mapfile before the damage is counted. The damage section reports
  `-` extents as "N unreadable extents, X bytes" and says that unreadable
  regions are zero-filled, that a listing exiting 0 is not proof of intact
  data, and that per-file attribution is a `copy` feature. **No mapfile is not
  zero damage**: the section says damage is unknown and the counters are
  absent. A mapfile that is present but unparsable is exit 30.
- **Partial success.** `ntfsls` exits 0 on a partial listing, so a non-empty
  stderr, a capped parse (2,000 entries) or a truncated process capture makes
  the listing `partial` and the run exit 1. `ntfsinfo` exiting 0 with an
  unreadable record is also partial. A listing that exits nonzero is exit 1
  (the volume did open); a listing timeout is exit 30.
- **Boot sector.** The primary sector is validated before any tool: OEM ID
  `NTFS    `, bytes/sector in {512, 1024, 2048, 4096}, sectors/cluster a power
  of two in 1…128, `55 AA`. An invalid primary is reported even when the tool
  only says "Invalid argument". **No restore happens unless
  `--restore-boot-sector --to <working-copy>` is given**, the destination does
  not exist, and the primary is invalid. The backup is at
  `partition_offset + partition_length_bytes - 512`, with the length from the
  partition table (the image size for a bare volume) — never the disk's last
  sector and never the BPB's `total_sectors`. It is validated with the same
  rules before the 512 bytes are written over the primary on the copy,
  `conv=notrunc`; the original is never written. The volume is then re-opened
  with `ntfsinfo` on the copy. A bad backup says "cannot restore" and the
  report falls back to volume-level damage (exit 30).
- **Non-NTFS.** APFS (`NXSB`), HFS+ (`H+`/`HX`), exFAT and FAT are named by
  their cheap magic and reported as `filesystem X: native read-only attach not
  implemented yet`, exit 30. No `diskutil`/`hdiutil` call is made.
- **The live test.** One integration test builds a 16 MiB NTFS image with
  `mkntfs` in a temp directory and inspects it bare and inside an MBR, through
  the real runner. It is enabled only when `bin/ntfsinfo`, `bin/ntfsls` and
  `sbin/mkntfs` exist (the spike tree beside the checkout, or
  `DISKTRIAGE_NTFS_PREFIX`). When they are absent it is **skipped**, never
  passed. `scripts/check.sh` counts a JUnit `<skipped>` case as FAIL, so a
  tool-less host fails the gate rather than greying it; that is a property of
  the gate's "a skipped check is never a pass" rule, recorded here rather than
  worked around.
- **Not implemented, deliberately.** Per-file damage attribution
  (`ntfscluster`), `copy`, and native APFS/HFS+/exFAT/FAT attach. The partition
  parser and the tool runner are reusable so `copy` can build on them.



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
