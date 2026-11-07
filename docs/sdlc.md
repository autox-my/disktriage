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

- `disktriage triage --from <signalset.json>` classifies a recorded set; live
  collection arrives with the collectors in P2. Without `--from` it says so on
  stderr and exits **30** (tool error). At P1b, `image`, `inspect`, `copy`,
  `check` and `list` also exited 30 with "not implemented yet (planned
  P2/P3)"; `inspect` is implemented in P3c and `copy` in P3c (below). No
  planned command remains.
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
- **Paths.** The CLI resolves the image, `--mapfile` and `--to` against the
  working directory to an absolute, standardized path before the command policy
  sees it; the policy itself stays absolute-only. Symlinks are resolved for the
  `/dev` refusal, so an ordinary-looking symlink to `/dev/rdiskN` is still a
  usage error (2). A policy rejection names the rejected argument.
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
  passed. `scripts/check.sh` answers **3** (UNVERIFIABLE) for a `<skipped>`
  case and names the skipped test, so a tool-less host greys the gate rather
  than passing or failing it; that is the gate's "a skipped check is never a
  pass" rule, and the gate is not relaxed to make the host look green.
- **Not implemented, deliberately.** Per-file damage attribution
  (`ntfscluster`) belongs to `copy` (below), and native APFS/HFS+/exFAT/FAT
  attach is still refused. The partition parser and the tool runner are shared
  with `copy`.

### CLI decisions (P3c, `copy`)

`disktriage copy <image> --to <dir> [--mapfile <path>] [--json]
[--hash-image]` copies the **file tree** of an NTFS volume out of an image,
read-only, with a SHA-256 per file and a manifest. It builds on `inspect`'s
partition parse, NTFS tool policy, mapfile parser (including the sidecar
`limit_bytes` clamp) and absolute-path resolution; none of that is duplicated.

- **Exit codes.** `0` copied, every written hash equals its read hash, and no
  damage was reported; `1` copied but the mapfile reports damage, the mapfile is
  incomplete, the copy is partial (a file failed, a cap was reached, a listing
  was partial) or per-file attribution is unavailable **on a damaged image**;
  `30` a precondition or tool error. The verdict codes 10–13, 20 and 21 are not
  copy's. `/dev/*` and a symlink to it are a usage error **2**, as are a missing
  image, a missing `--to` and unknown flags.
- **Images only.** A non-regular file is refused. The source is opened
  read-only everywhere; only `--to` is written. A test hashes the image before
  and after the run.
- **Destination.** Created (with parents) when missing. An existing path that is
  not a directory is **30**. Before the first write, every destination path and
  the reserved `MANIFEST.json`/`SUMMARY.txt` are checked; **copy never
  overwrites a file**, so any collision is **30** with the target named. Paths
  are preserved relative to the volume root.
- **Names.** A listed name with a `..` component, an empty component, a NUL byte
  or a leading `/` inside a component is refused (**30**) before anything is
  written. It is never sanitised into a different name.
- **Tools.** The same `DISKTRIAGE_NTFS_PREFIX` → PATH → Homebrew/system lookup
  as `inspect`, extended to all four tools: `ntfsinfo -m`, `ntfsls -l -R`,
  `ntfscat <image> <volume-path>` and `ntfscluster -c 0-(N-1) -v`. The command
  policy accepts only those exact read-only shapes (an absolute image outside
  `/dev`, a numeric cluster range, no `-f/--force`, no `ntfsfix`, no writer).
  Missing tools are **30** with the prefix hint; there is no mount fallback.
  Timeouts: 30 s for `ntfsinfo`, 120 s each for the tall listing, one file read
  and the run map, always with a process-group kill.
- **What is copied.** File data (`$DATA`) only, at the volume's relative paths;
  directories (including empty ones) are recreated. Facility metadata such as
  security descriptors and alternate data streams is not copied in v1. A
  whole-disk image is extracted to a temporary working file exactly as `inspect`
  does, so cluster numbers stay volume-relative; the temporary file is removed.
- **File data is bytes, not text.** `ntfscat` output is streamed through
  `ProcessRunner.stream` in bounded chunks; a UTF-8 decode would corrupt it and
  buffering the whole stdout is not allowed (see the streaming decisions below).
- **Hash while copying.** SHA-256 of the bytes consumed from `ntfscat` and of the
  bytes read back from the temporary file. The read-back is what proves the write
  landed and catches a corrupting writer; a difference is `1` and the entry says
  `hash-mismatch`. The manifest digest is a SHA-256 of the entries' path, size,
  hashes and status. Output and `notes` say that equality proves the copy matches
  the **image**, not that the image matches the platter.
- **Caps.** 10,000 listing entries, 2 TiB per file, an optional
  `--max-bytes <GiB>` run cap and 1,800 s per run. A cap is reported in `notes`
  and makes the copy **partial** (exit 1); it never silently truncates a file or
  pretends the tree is complete.
- **Manifest.** `<dir>/MANIFEST.json`, schema `disktriage.copy/1`, version 1,
  tool version, `created_at`, image path and size, `image_sha256` (null by
  default with a note saying `--hash-image` was not passed; a multi-GB hash is
  expensive), a `source` mapfile summary, `damage.scope = "volume"` with the
  unreadable extent and byte counts (null, never 0, when unknown), per-file
  entries {path, size, sha256_read, sha256_written, integrity, attribution,
  status, note}, and a top-level `attribution` with `kind` `ntfscluster` or
  `none` plus `reason`. `<dir>/SUMMARY.txt` is the same human report.
- **Damage baseline.** The mapfile is `--mapfile`, else `<image>.mapfile` when it
  exists, clamped by the image sidecar's `limit_bytes`; no mapfile means damage
  **unknown** (`status: unsupported`, null counters), never zero. A mapfile that
  exists but does not parse is **30**. `inspect`'s wording is reused with a
  copy-specific note.
- **Per-file attribution (NTFS, one pass).** One
  `ntfscluster -c 0-(nr_clusters-1) -v` (120 s, 200,000 parsed runs, 48 MiB
  process cap). Each `-` mapfile extent becomes a volume-relative cluster range
  by subtracting the partition offset, dividing by the cluster size and rounding
  **outward** (a partly bad cluster is wholly bad), then intersecting locally
  with every inode's LCN runs. Extents are never merged into one min-max span: a
  file in a good gap stays `intact`, and an extent in an unallocated gap is
  reported at volume level. A normal file's `$DATA` run marks that file
  `integrity: overlaps-bad-extent`; `$MFT`, `$MFTMirr`, `$LogFile`, root
  `$INDEX_ALLOCATION` and similar metadata are named verbatim and kept at volume
  level (no per-file claim); a damaged non-root directory index marks that
  directory's immediate children `metadata-damaged`, which is the one metadata
  case that can be localised.
- **No flag-everything fallback.** If the run map is unavailable — timeout,
  error, process/output cap, 200,000-run cap, empty map, or the volume size in
  clusters is unknown — `attribution.kind` is `none` with the reason and **no
  file carries an integrity value**. Files are never all marked `unknown`. On a
  damaged image that is exit 1; on a clean mapfile it is not itself damage.
- **Not the fallback.** The plan's per-extent `ntfscluster -c <range>` fallback
  is not implemented; a failed one-pass run reports volume level and the run is
  recorded as a gap, not guessed at.
- **The live test.** One integration test copies the spike's
  `damaged-clip-part.img` with its mapfile through the real runner and asserts
  `/media/clip.dat` is `overlaps-bad-extent` while `/docs/readme.txt` is
  `intact`. It is enabled only when all four tools and that gitignored image are
  present; otherwise it is **skipped**, which the gate answers as **3**, never
  a pass.
- **Not implemented, deliberately.** Other filesystems (named and refused with
  `native read-only attach not implemented yet`), boot-sector restore inside
  `copy` (use `inspect --restore-boot-sector` on a working copy first), resume of
  an interrupted copy, and per-extent fallback attribution. File data only: a
  metadata-complete file copy (security descriptors, ADS) is a later feature.

### CLI decisions (P3c, streaming `copy`)

`copy` used to buffer each `ntfscat` stdout in memory. It now streams, so peak
memory is one chunk regardless of file size. The contract did not change for
small files: the same manifest, the same hashes, the same exit codes.

- **The stream is `ProcessRunner.stream`.** It is a sibling of `runData`, not a
  weaker path: the same `CommandPolicy` check before `exec`, the same hard
  timeout, and the same `TERM`-then-`KILL` to the process group. stdout is read
  non-blocking through one pipe in `CopyLimits.streamChunkBytes` (1 MiB) chunks;
  stderr is drained concurrently and still capped by `outputLimit`. A throwing
  sink stops the child, so a full disk never leaves a tool writing into a pipe.
- **Memory is O(chunk).** The read-side SHA-256 is updated incrementally,
  including the final partial chunk; the chunk is written to the temporary file
  before it leaves the loop. `--max-bytes` and the per-file bound are checked
  before a chunk is written, so a cap never creates a partial final file.
- **A file is installed only after its read-back.** Data goes to
  `.<name>.disktriage-partial.<uuid>` beside its target. `sync` fsyncs it, a
  bounded read-back re-hashes those bytes, and only an agreeing read-back calls
  `commit`. `commit` fsyncs again and installs with `link`+`unlink`, which is an
  atomic no-replace operation: a file that appeared at the destination is a
  failure, never an overwrite. Any failure, timeout or cap calls `abort`, which
  deletes the temporary file; a process that dies leaves a visibly partial name,
  never a plausible final one.
- **Unfinished is `incomplete`, never copied.** A stream that ends by timeout or
  cap, or a write/read-back failure, records `status: "incomplete"` with the
  bytes streamed and a note saying the partial file was discarded. It is not
  `ok`, not counted in `files_copied`, and makes `copy.status` `partial` (exit
  1). A complete-but-corrupt write is `hash-mismatch`; a tool that never
  produced data keeps `read-error`.
- **Caps are not memory bounds.** The per-file sanity bound is 2 TiB and is
  refused before a read when the listing names the size. `--max-bytes <GiB>`
  (positive whole GiB; zero, a fraction or a non-number is usage error 2) is the
  only run-wide byte cap; without it the 1,800 s run budget and the per-tool
  hard timeouts remain. Hitting either prints the cap and the remaining file
  count; the manifest's `copy.max_bytes` is the cap in bytes (null when absent).
- **Test seams.** `CopyDependencies.chunkSize` (a tiny chunk in tests),
  `maxBytesOverride` (a byte-level cap for sub-GiB fixtures) and
  `CopyChunkObserving` (acquire/release around each chunk) exist so the suite
  can prove one-chunk-at-a-time ownership without a flaky RSS measurement.
  `catFileStreaming` is the injected tool seam; the recorded-output doubles use
  a chunking default and the live runner overrides it with the real pipe.

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

## Local snapshot history (P1f, `smart.history`)

`triage` keeps a small local store so the trend rule (`reallocated` rising vs a
prior snapshot -> MEDIA, exit 10) can fire on a real prior reading. It is the
one write triage can make, and the plan calls it optional (diskdoctor.md §4, §6).

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
- **Failure is a note, not a verdict.** A failed snapshot write is printed on
  stderr and leaves the verdict and exit code exactly as the classifier chose
  (REQ-0160). The same holds on this Mac's USB drives: SMART is unreadable there,
  so the run reports `history: unavailable (SMART unsupported is not a
  measurement; ...)` and writes nothing — absent is never a zero.

## Identity while DiskArbitration is stopped (P3b follow-up)

`guard --suspend` and `image`/live `triage` used to be mutually exclusive: the
guard SIGSTOPs `diskarbitrationd`, and P0 phase C measured that `diskutil`
then hangs system-wide, while the device collector read identity through
`diskutil info -plist`. The collector now has an ioreg path that never waits on
a hung `diskutil`.

- **The stopped-daemon probe reuses the guard's argv.** `pgrep -x
  diskarbitrationd`, then `ps -o stat= -p <pid>`, through the injected runner;
  both exact shapes are on the triage allow-list. Only a positive stopped
  state (`ProcessState.isStopped`, the same T-prefix rule the guard's suspend
  check uses) skips `diskutil`. A failed or unknown probe falls through to the
  normal `diskutil` path, so an unreadable state is never treated as a guard.
- **The ioreg path is two read-only shapes.** `ioreg -r -c
  IOBlockStorageDevice -w 0 -l` gives the device's `Device Characteristics`
  (product, vendor, serial, medium type), `Protocol Characteristics`
  (interconnect and location) and its whole-disk `IOMedia` child (`BSD Name`,
  `Size`, `Preferred Block Size`, `Whole`, `Removable`, `Ejectable`). When the
  block device exposes no serial, one further query, `ioreg -r -c
  IOUSBHostDevice -w 0 -l`, supplies the USB host device's `USB Serial
  Number`; the association is the same `BSD Name` in the same subtree, never
  order-based. `-t` is deliberately not used: it prints every ancestor's
  properties, which can exceed the runner's output cap before the device
  appears.
- **The source and the reason are recorded.** A `DeviceCollection` now carries
  `source: diskutil | ioreg` and, on the stopped path, the reason line
  `diskarbitrationd is stopped; diskutil skipped`. A `diskutil` timeout for any
  other reason also falls back once to ioreg and keeps the timeout as evidence
  (`diskutilTimeoutMs`, plus `timed out after N ms` in the reason); the run
  does not become exit 30 because identity succeeded, and a failed fallback
  keeps both failures.
- **Absent stays absent.** A serial the ioreg tree does not expose stays
  `nil`; the image confirmation then asks for `--confirm-size <GiB>` exactly as
  before. A hex-encoded USB serial is decoded only when every byte is printable
  ASCII (a real ASCII serial such as `0ba01062e2bc880e` is left alone), and an
  empty `Product Name`/`Vendor Name` is `nil`, not an empty value.
- **`DISKTRIAGE_FORCE_IOREG=1` is a test-only override.** It forces the ioreg
  path so a healthy Mac can exercise it without suspending a system daemon; it
  is not a supported CLI flag and is documented here only so the smoke result
  is reproducible. `triage --from` is untouched.
- **What is still not covered.** `enumerate()`/`list` now use the same ioreg
  path (see the follow-up below), but the ioreg identity still leaves
  `virtualOrPhysical` nil for a physical disk (only a synthesized APFS media
  is marked `Virtual`) and reports `media` as `unknown` when `Medium Type` is
  absent, which is the P0-measured USB case.

## The stopped-DA rule reaches the rest of the image path (P3b follow-up)

The identity fix above left three `diskutil` calls on the same paths. P0 phase C
measured that a suspended `diskarbitrationd` makes every one of them hang, so
they now ask the same `DiskArbitrationProbe` the collector uses, and a timeout
still falls back once.

- **Enumeration.** `DeviceCollector.enumerate()` reads whole disks from
  `ioreg -r -c IOBlockStorageDevice -w 0 -l` while stopped (or forced), and
  after a `diskutil list` timeout. The pure `IORegDeviceParser.wholeDisks`
  keeps `Internal` from `Protocol Characteristics`, marks `AppleAPFSMedia` as
  virtual (so the FDA probe never reads a synthesized container), and the list
  is sorted by disk number so `list` reads the same either way.
- **The destination's backing disk.** `SystemImageDestinationProbe` keeps
  `statfs` (`f_mntfromname` of the destination or its nearest existing parent)
  and then walks with `diskutil` when it is safe. While stopped it uses
  `ioreg -r -c IOMedia -w 0`, whose parent links are the APFS walk: `disk3s5`
  → `disk3` (container) → `disk0s2` (store partition) → `disk0`. The pure
  `IORegMediaTree` returns every store of a multi-store container. A mount
  source that is not `/dev/disk*` (a network share, `map auto_home`) and a
  container with no physical store are **unknown**, and the
  "not on the source disk" check reports **unverifiable**; `image` refuses
  with exit 30. The source side of the comparison is still its whole-disk name.
- **`check`.** The filesystem-personality row returns
  `UNVERIFIABLE diskarbitrationd stopped; diskutil skipped` instead of calling
  `diskutil listFilesystems`.
- **Evidence.** `DISKTRIAGE_FORCE_IOREG=1` drives both destination paths on a
  healthy Mac. On the reference machine the old and new paths agreed:
  `/Users/fd/Projects/diskdoctor/captures/image-smoke/x.img` → `disk0` (APFS;
  the same volume and free-space reading), whole disks `disk0…disk7` in the
  same order, and the internal probe node `/dev/rdisk0` by both paths.
- **Unchanged.** With the daemon running, identity, enumeration and the
  destination walk still use `diskutil` first; the suite drives the whole
  `image --no-dry-run` flow with a fake ddrescue and asserts both the
  zero-diskutil stopped run and the diskutil-first running run.

## Mapfile accounting: failed is not bad (P3b follow-up)

The first real `disktriage image --limit 10` run on the failing MiNaH drive
(WD3200BJKT, 131 pending sectors) printed `BAD 0 bytes` and `0 unreadable
extents` while its mapfile held 12 `*` extents of 64 KiB. The statuses are not
interchangeable: in GNU ddrescue 1.30's mapfile, `?` is non-tried, `*` failed
during copying and is not yet trimmed, `/` is trimmed but not scraped (both
contain read errors), `-` is a confirmed bad sector, and `+` is finished.

- **Four quantities, never merged.** `MapfileSnapshot` keeps rescued (`+`),
  untried (`?`), failed (`*` + `/`) and bad (`-`) apart, each with its byte
  total and extent count (`failedBytes`, `failedExtents`, `badBytes`,
  `badExtents`; the older `nonTrimmedBytes`/`nonScrapedBytes` remain).
- **The summary never hides damage behind `BAD 0`.** The human summary always
  prints `FAILED  X bytes in N extents (read errors seen; not yet trimmed or
  scraped)` and `BAD  X bytes in N extents (confirmed)`. The live progress line
  carries the failed bytes and extent count too. JSON keeps `bad_bytes` and
  `remaining_bytes`/`remaining_extents` and adds `failed_bytes`,
  `failed_extents` and `bad_extents`; the old keys stay.
- **`inspect` and `copy` count failed and bad together as unreadable.** An
  extent with a read error is unreadable so far whether or not ddrescue has
  isolated it, so `unreadable_extents`/`unreadable_bytes` are failed + bad.
  The damage line also shows the split (`(12 failed, 0 confirmed bad)`), and an
  incomplete mapfile adds: failed extents may shrink after trimming and
  scraping. The JSON damage section adds `failed_extents`, `failed_bytes`,
  `bad_extents` and `bad_bytes`. `copy` writes the same four fields into the
  manifest's damage section.
- **The partial-image clamp is unchanged (REQ-0108).** Every accounting runs
  inside `[0, limit)` exactly as before; failure simply has its own bucket now.
  The real MiNaH mapfile measured 12 failed extents (786,432 bytes), not 13.
- **Fixture and reason.** `Tests/Fixtures/minah-partial-me.mapfile.txt` is the
  real run with its local paths redacted; `mapfile-trimmed-bad.mapfile.txt` is
  the same drive after trimming (12 `-` extents) and
  `mapfile-nonscraped.mapfile.txt` is the `*`/`/` table. The expectations come
  from the status meanings above, not from the parser.

## The stop reason is ddrescue's own exit (P3b follow-up)

The same run ended with `STOPPED  ddrescue error` after 996 s although the node
was present, no SIGINT was sent, and ddrescue had been invoked with `-T 90`.
ddrescue stopped itself: `-T` is "maximum time since last successful read", so
a bad region that stalls reads is enough. A generic "error" hid both the code
and the explanation.

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
- **Unchanged.** Every non-complete outcome except a launch failure still exits
  **1** and keeps the mapfile; resumability and the printed resume command are
  untouched. `stop rule` is now spelled `pass-2 stop rule`.

## `check` does not wait on a stopped diskarbitrationd (P3 follow-up)

`disktriage check` did not return within 120 s with `guard --suspend` active,
even though the `diskutil listFilesystems` row already skipped. The audit found
the remaining blocker: `mountGuardAvailable` called `DASessionCreate`, a
synchronous DiskArbitration call that talks to the stopped daemon with no
timeout.

- **The rows that touch DiskArbitration ask first.** `mount-guard` returns
  `UNVERIFIABLE diskarbitrationd stopped; DASessionCreate skipped`; the
  filesystem row keeps `diskarbitrationd stopped; diskutil skipped`. Both use
  the same `DiskArbitrationProbe` (a positive `T` state from `pgrep`/`ps`) as
  the collector and the image path; a failed probe falls through, so an
  unreadable state is never treated as a guard.
- **Everything else runs or is bounded.** The raw-device row reaches
  `DeviceCollector`, which uses ioreg while stopped and never `diskutil`. The
  tool rows run `--version` under the check policy's hard timeout. The unified
  log probe has its hard timeout. The `diskarbitrationd state` row now runs its
  `pgrep`/`ps` through the injected runner with the runner's hard timeout,
  instead of a bare `Process` with no deadline.
- **The seam test.** No test stops a system daemon. One test injects a runner
  where every diskutil shape returns a timeout and `pgrep`/`ps` report `T`,
  then runs the whole `CheckRunner`: both DiskArbitration rows are
  UNVERIFIABLE with the reason, no diskutil command is attempted, and the
  run completes in well under 5 s. There is still no in-process timeout for
  `DASessionCreate` when the daemon is running but wedged; the skip covers the
  measured failure, and a wedged-but-running daemon is a finding, not a pass.
- **The ntfs-3g row names what it searched.** The real run printed
  `missing ntfsls, ntfscat` while `inspect` found `ntfsls` under the same
  prefix. Resolution was already shared; the row collapsed every non-PASS
  into "missing" and printed no path. `ntfsls --version` prints its banner and
  **exits 1**, so a present binary looked absent. A found ntfs tool whose
  `--version` exits non-zero is now `PASS` when it printed its banner (or
  `UNVERIFIABLE` when it printed nothing), and a genuinely missing tool's
  message names `DISKTRIAGE_NTFS_PREFIX`, PATH and the fallback directories.

## Allocation-aware NTFS stage 0 is a pure library (v3.8)

`diskdoctor.md` §8's "Allocation-aware order for NTFS" now has its pure core in
`DiskTriageCore`: boot geometry, the stage-0 read plan, MFT record parsing, the
`$Bitmap` decoder, the allocation domain and a ddrescue domain-mapfile writer.
No CLI, ddrescue invocation or staging is added here; a later change wires it
into `image`. The library does no I/O, starts no process and reads no file.

- **Boot geometry.** `NTFSBootGeometry.parse` reuses the inspect work's rules
  through a new typed `NTFSBootSectorRules.validateTyped` (the old `validate`
  is now its text projection, so there is one implementation). It adds the
  `$MFT`/`$MFTMirr` LCNs and the signed record-size encoding (`-n` = `2^n`
  bytes, positive = clusters). An MFT LCN at or past the volume end is a typed
  failure. `NTFSBootGeometry.select` validates the backup at
  `partition_offset + partition_length_bytes - 512` and reports
  `primary | backup`; two bad sectors are `.noUsableBootSector`.
- **Stage-0 plan.** `NTFSStage0ReadPlan.plan` is two-step. Before geometry it
  lists the partition table (including the GPT backup header and entry array
  when `deviceSize` is known), the primary boot sector and the backup boot
  sector. Once geometry exists it appends the first 16 MFT records at the MFT
  LCN. The caller performs the reads.
- **MFT records.** `NTFSMFTRecord.applyFixups` verifies every sector tail
  against the USA and restores the originals; a mismatch is a torn record and
  a typed failure. `dataAttribute` decodes an unnamed `$DATA`: resident bytes
  or a non-resident run list. `NTFSRunList` reads the mapping pairs with
  signed offset deltas and sparse runs, and rejects overlap, a run past the
  volume end and fragmentation over the cap. An `$ATTRIBUTE_LIST` is a typed
  `unsupported`, never followed.
- **`$Bitmap`.** Bits are least-significant first; used clusters are
  coalesced; bits past `total_clusters` are ignored. A short bitmap is a typed
  failure. `$Bitmap`'s last byte in the spike image has bit 16383 set past a
  16383-cluster volume; counting it would report 12309 used clusters, not the
  tool's 12308.
- **Domain and free space.** `NTFSAllocation.allocationDomain` unions every
  `$MFT` run, the 16-record metadata region and the used cluster runs, adds
  the partition offset, merges/sorts and clips to the partition, and returns
  the complement for stage 2. `NTFSAllocation.evaluate` is the one-call stage-0
  path; when the MFT record, bitmap record or bitmap bytes are unavailable it
  returns `.unknown(reason)`. "Unknown" is never "everything free", and the
  writer only accepts a domain, so a failed stage 0 cannot produce a mapfile
  that skips free space.
- **Domain mapfile.** `DdrescueDomainMapfile.render` writes `# Mapfile. Created
  by disktriage`, a `current_pos` row, `+` for domain extents and `?` for the
  rest. `ddrescue -m` treats the `+` blocks as the domain. The round trip goes
  through the shipped `DdrescueMapfile` parser.
- **Fixtures.** `Tests/Fixtures/ntfs-disk-*` are the few KiB the parser needs
  (both boot sectors, `$MFT` records 0 and 6, `$Bitmap`, the raw
  `ntfscluster` output and the coalesced used-run list), recorded from the
  gitignored `captures/ntfs-spike/img`. `ntfs-disk-notes.md` records the
  ntfsinfo/ntfscluster readings and the commands. On the spike image the tools
  report 16383 clusters, 4075 free and 12308 used; the bitmap yields the same
  10 runs (0-2, 4-3710, … 16266-16382). Fixture and expectation move together.
- **Live tests are skippable, the pure tests are not.** One test writes an
  8 MiB source and an 8 MiB domain mapfile and runs real `ddrescue -m`, then
  asserts the domain bytes match and the gaps are zero. Two more read the real
  `disk.img` and compare the bitmap's runs with the recorded `ntfscluster`
  output and check every file data run is covered by the domain. When
  ddrescue or the capture is absent the test is `<skipped>`, which the gate
  answers as **3**, never a pass; the pure tests in
  `DiskTriageCoreTests.NTFSAllocationTests` always run.
- **Mutation checks.** (a) not restoring the USA tails, (b) backup offset
  `-1024`, (c) unsigned run offsets, (d) MSB-first bitmap bits, (e) counting
  the tail bit past the volume, and (f) treating an unread bitmap as all-free
  each turned the named test red; restoring each turned it green.
- **Judgement calls and plan gaps.** `$ATTRIBUTE_LIST` is unsupported by
  design (record 0/6 here have none); following extension records is a later
  feature. A sparse `$MFT` run contributes no physical extent. The stage-0 MFT
  region assumes records 0-15 start inside the first `$MFT` run (true at the
  spike's LCN 4, 31-cluster run); a fragmented `$MFT` whose first run is
  shorter needs the run map from record 0 first. The run-list cap is 65,536
  runs. 4Kn sectors are parsed but untested (the plan already leaves 4Kn
  unverified). No change is made to `diskdoctor.md`; the above are findings.
