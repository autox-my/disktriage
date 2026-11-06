# disktriage — disk triage & rescue CLI

**Status:** draft plan v3 (revised after two reviews — see §14)
**Date:** 2026-11-06
**Origin:** the MiNaH recovery (WD3200BJKT, 131 pending sectors, 320 GB, 99.99% imaged, 490,645 files recovered)

---

## 1. Problem

macOS hides storage failure. On the MiNaH drive, the kernel knew exactly what was wrong —
`medium error, LBA 2048, Medium Error / Unrecovered read error` — but that information never
reached a human:

- the volume simply would not mount, with no technical detail;
- `diskutil` sometimes did not even enumerate the partition;
- `dmesg` does not exist; the unified log is unread;
- raw block devices are TCC-gated, so imaging is impossible without Full Disk Access — even as root;
- a third-party NTFS driver turned a retrying read into an indefinite hang, making a **dying** disk
  look **dead**.

Linux had the same drive, the same kernel, and produced a one-line diagnosis, an image, and a
sector map in a few commands.

**The gap is not capability. It is diagnosability, and knowing the safe order of operations.**

The rule that mattered:

> If a volume won't mount: stop. Read SMART. Image the device. Only then touch a filesystem.

Nobody follows that rule, because nothing enforces it.

### Scope (v1)

External spinning disks (USB/Thunderbolt-attached HDD), optionally SATA SSDs.
**Out of scope for v1 *classification*:** internal Apple NVMe, SD cards, USB flash, RAID/Fusion
sets. They fail differently (wear, controller lockups, read-only mode) and SMART attributes such as
197 are an HDD concept. The tool must detect these device types and say "unsupported", not guess.

**Unsupported means "no diagnosis", not "no action".** Image first, never mount, is valid for every
failing medium — a corrupt camera SD card is a prime case, and controller lockups and read-only mode
are exactly where imaging-first wins. So the verdict and the action are separate: `UNSUPPORTED`
media get no classification, but `image` stays available with a caveat. `list` and `triage` label
them "triage not applicable" and never imply a health judgment (this matters most for internal
NVMe, which the collector will see).

### Non-goals

- Not a file-recovery GUI. It triages, images, and hands off.
- Not a SMART dashboard. DriveDx and CrystalDiskInfo do presentation better.
- Does not promise to recover data, does not predict how much will be lost, and must never imply a
  disk is safe without evidence.
- Does not repair filesystems in place, ever.

---

## 2. Design principles

1. **Never mount the source device.** Triage reads hardware signals only. Inspection happens on
   the image. A read-write driver writes (journal replay, dirty flag); a read-only mount still
   trusts a failing device to answer every block. Because `diskarbitrationd` automounts at
   plug-in, enforcement needs an active mount guard (see §8), not just good intentions.
   **Measured limit (P0 row 5):** a dissent stops the *mount*, but a third-party driver's probe
   (`ms_ntfs.util -p` / `-k`) still reads the volume before the approval is asked. The principle is
   therefore "never mount", not "never touch": macOS and its drivers may read the boot sector and
   early metadata as soon as the disk is visible to it.
2. **Diagnosis must not require FDA.** Only imaging does. Triage triggers no TCC prompts.
   *Honest caveat:* triage does depend on third-party tools (`smartctl`) and may need root
   (sudo). "Stock Mac" applies to the permission model and the filesystem drivers, not to the
   tooling. `check` reports exactly what is missing.
3. **Insufficient evidence is a verdict.** Exit code, message, and prescription for "I don't know".
   An **absent signal is never a zero**: every signal carries a status (`ok | denied |
   unsupported | timeout | error`), and counters are nullable.
4. **No third-party filesystem driver dependency.** Stock macOS only for mounting. Detect drivers,
   never require or install one. macOS 27.2 has **no native NTFS mount helper** (P0 A2), so NTFS
   inspection uses the ntfs-3g **userspace tools** (`ntfsinfo`, `ntfsls`, `ntfscat`, `ntfscluster`)
   as a GPL subprocess **on the image only**: no mount, no FUSE, no kernel extension, no root, no
   FDA (spike: `docs/ntfs-spike.md`). Native read-only mounts remain for APFS/HFS+/exFAT/FAT.
   *Exception, stated up front:* there is no native NTFS repair on macOS, so NTFS repair is a
   documented **hand-off** (§8), never something the tool performs on the original.
5. **Ranked differential, not a health score.** Output the top hypothesis, the evidence, what would
   falsify it, and the single cheapest next test.
6. **Never destroy evidence.** Every operation is read-only until the user explicitly asks to write,
   and writes only ever target an image or a copy destination.
7. **The tool must not hang with the disk.** Every collector is an isolated subprocess with a hard
   timeout and process-group kill. A timeout is itself a signal (device unresponsive), not a crash.
   Triage uses a fixed allow-list of read-only commands and never starts SMART self-tests.

---

## 3. Architecture

Portable core, platform collectors.

```
                    ┌─────────────────────────────────────┐
                    │ core (no OS calls)                  │
                    │  SignalSet  →  Classifier  →  Verdict│
                    │             Renderer (tty | json)    │
                    └───────────────▲─────────────────────┘
                                    │ SignalSet
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
  collectors/macos           collectors/linux           collectors/windows
  ioreg, diskutil -plist     sysfs, dmesg, lsblk        Get-PhysicalDisk
  smartctl -d sat            smartctl                   Get-StorageReliabilityCounter
  unified log                journalctl -k              smartctl, Event Log
  /Library/Filesystems       /sys/block/*/device        MSStorageDriver_*
        │
  imaging: ddrescue subprocess (with mapfile, resume, verify)
```

The **classifier is a pure function** over a `SignalSet`. It is the product. Everything else is
plumbing, and the classifier is testable with zero hardware — replay recorded signal sets as
fixtures.

### SignalSet — the contract

Rules: versioned; every section has a `status`; counters are `null` when unknown; user-supplied
observations are first-class signals; all times are UTC.

```json
{
  "schema_version": 1,
  "collected_at": "2026-11-06T00:14:02Z",
  "device": {
    "status": "ok",
    "bsd": "disk4", "size_bytes": 320072933376,
    "model": "WDC WD3200BJKT-75F4T0", "serial": "WD-WX0123456789",
    "media": "hdd", "bus": "usb", "bridge": "generic-sata", "sat_passthrough": "partial",
    "removable": true
  },
  "smart": {
    "status": "ok", "overall": "PASSED",
    "pending": 131, "reallocated": 14, "uncorrectable": 0,
    "power_on_hours": 4531, "raw_read_errors": 21545,
    "error_log": [{ "lba": 2048, "type": "uncorrected-read", "count": 6 }],
    "self_test": { "last": "completed-no-error", "age_hours": 20 },
    "history": null
  },
  "io": { "status": "ok", "retries": 1204, "timeouts": 3 },
  "log": {
    "status": "ok", "window_hours": 72,
    "events": [{ "time": "2026-11-06T00:12:31Z", "kind": "medium_error", "lba": 2048, "count": 6 }]
  },
  "drivers": {
    "status": "ok",
    "items": [{ "path": "/Library/Filesystems/iboysoft-ntfs.fs", "third_party": true, "claims": ["ntfs"] }]
  },
  "permissions": { "root": true, "raw_read": "denied", "removable_volumes": "granted" },
  "fs": { "status": "ok", "type": "ntfs", "partition_start_lba": 2048, "mounted": false, "readable": null },
  "symptoms": { "source": "user", "clicking": false, "disappears": false, "works_on_other_port": null,
                "works_with_other_cable": null, "works_with_other_enclosure": null },
  "collector_notes": [{ "collector": "diskutil", "outcome": "timeout", "after_s": 10 }]
}
```

Notes:

- `io.bitflips` / `io.no_dma` from v1 draft are **removed**: no known macOS source. Re-add only if
  P0 finds one.
- `symptoms` carries what software cannot observe (clicking, swap-test outcomes). They are
  supplied with flags (`--symptom clicking`, `--tried cable`) or an interactive prompt.
- `smart.history` comes from a local snapshot store keyed by hashed serial
  (`~/Library/Application Support/<tool>/history/`). It enables trend rules (§5) and can be
  disabled with `--no-history`. It is `null` on first sight of a drive (as in the MiNaH fixture);
  trend rules never fire without a real prior snapshot, and fixtures must not invent one.
- Devices are keyed by serial / IORegistry path, never by `diskN` alone — the BSD name changes on
  reconnect.

### Verdict

Root cause and aggravating factors are separate. Confidence follows the rules in §5.

```json
{
  "causes": [
    { "class": "MEDIA", "confidence": "high",
      "evidence": ["pending=131", "reallocated=14", "medium error @ LBA 2048"],
      "falsified_by": "readable image with zero bad areas",
      "cheapest_test": "image the device; inspect the mapfile" },
    { "class": "BRIDGE", "confidence": "low",
      "evidence": ["timeouts=3", "sat_passthrough=partial"],
      "note": "pending sectors are drive-internal; the bridge cannot explain them" }
  ],
  "aggravators": [
    { "class": "DRIVER", "confidence": "medium",
      "note": "third-party NTFS driver claims the volume; may block on retrying reads" }
  ],
  "verdict": { "code": 10, "headline": "degrading, not dead; extent of loss unknown until imaged" },
  "next": { "command": "disktriage image disk4 --to /Volumes/Scratch/minah.img",
            "why": "reading the platter once is the only step that cannot be lost to further degradation" }
}
```

---

## 4. Platform strategy

| Platform | Value | Effort | Decision |
|---|---|---|---|
| **macOS** | High — information is deliberately hidden | High — TCC | **v1** |
| Linux | Low — `dmesg` + `smartctl` already legible | Low, once core is split | v2, nearly free |
| Windows | Medium — CrystalDiskInfo owns it | Medium | defer / skip |

Collector mapping:

| Signal | macOS | Linux | Windows |
|---|---|---|---|
| identity, bus, bridge | `ioreg`, `diskutil info -plist` | `lsblk -J`, `/sys/block` | `Get-PhysicalDisk` |
| SMART | `smartctl -d sat -a` (**P0: does opening the device trip TCC? per-bridge support?**) | `smartctl -a` | `smartctl`, `Get-StorageReliabilityCounter` |
| I/O error counters | `ioreg -r -c IOBlockStorageDriver -k Statistics` (**P0 B2: real Bytes / Operations / Retries / Errors counters; no timeouts counter; movement on bad media UNVERIFIED**) | `/sys/block/*/device/ioerr_cnt` | reliability counter |
| kernel error history | unified log predicate (**P0: retention?**) | `dmesg` / `journalctl -k` | Event Log |
| installed FS drivers | `/Library/Filesystems`, `systemextensionsctl list` | `/proc/filesystems`, `lsmod` | filter drivers |
| raw access | FDA-gated, plus root | free as root | admin |

**SMART over USB on macOS needs verifying, not fearing.** `smartctl -d sat` is userspace ATA
pass-through; the main variable is per-bridge support (some bridge families are reported to work,
many cheap ones do not), plus whether older setups needed a third-party SAT SMART driver. The
narrower question that decides the onboarding story is whether `smartctl`'s device-open path trips
TCC or needs root — one command to answer in P0 (item 1). The origin case does not answer it: the
MiNaH SMART data came from Linux (`smartctl -d sat` on the PVE host), so the macOS path is
unproven. If SMART is mostly unavailable, `BRIDGE` / "SMART hidden" is the *common* path and §5
must make it useful on its own (kernel log, I/O stats, symptoms, imaging advice), not an error
branch.

**Measured (P0 phase B, Seagate Expansion bridge 0bc2:231a, macOS 27.2):** `smartctl` cannot reach
SMART through this bridge even as root with Full Disk Access ("Not a device of type 'scsi'" /
"Operation not supported by device"), and `diskutil` reports `SMARTStatus: Not Supported`. The cause
is the OS/bridge path, not permissions. Two unrelated bridges (Seagate Expansion built-in, and a VLI bridge with a Samsung SSD 850 EVO) fail
identically on all 11 smartctl device types, so this is macOS-wide for USB mass storage, not
bridge-specific. Over USB, `diskutil` also gives no `SolidState` key for HDD or SSD, so media type is
`unknown`. Consequences: the no-SMART path carries triage; `io.timeouts` is **not**
available from ioreg (which exposes Retries and Errors) and must come from the kernel log or the
collector's own timeouts.

**Measured on the MiNaH drive (P0 phase C):** with SMART unavailable, the signals that exist are the
kernel log and ioreg. The unified log (readable without root) carries `[External] I/O error! ... Sense
Data 0x03, 0x11, 0x00` (medium error, unrecovered read) followed by `I/O error ... lba 0x800 count N,
retry 1..20` (LBA in hex, retries about 2.2 s apart), then `diskN: I/O error.`; repeats may be
coalesced (`happened 42 times`). ioreg `Errors (Read)` moved 0 -> 1, while `Retries` stayed 0 despite
20 kernel retries, so `Errors` is usable and `Retries` is not a reliable source. A single read of an
unreadable region blocks for about 45-50 s before failing, so collectors that read media need a
timeout of at least 90 s and must not be treated as hung before then; `ioreg` / `log show` do not
read media and stay fast.

**Bounded v1 scope: macOS only.** Keep the `SignalSet` and classifier free of OS assumptions so
Linux is a collector, not a rewrite.

---

## 5. Triage decision tree

Hardware signals only. No mounting. Every step records the signal's `status`; `denied`,
`timeout` and `unsupported` are different from "zero".

```
[0] enumerate           ioreg + diskutil -plist          no permission needed
[1] device present?   ── no ──▶ CABLE / PORT / BRIDGE          swap, retest
[2] media supported?  ── SSD/NVMe/flash/SD ──▶ UNSUPPORTED     say so, hand off
[3] SMART readable?   ── no ──▶ BRIDGE HIDES SMART             not a health signal; continue
[4] SMART counters    ── pending|uncorr > 0 ──▶ MEDIA          IMAGE NOW
                      ── reallocated rising vs snapshot ──▶ MEDIA
                      ── reallocated > 0, stable/no history ──▶ MEDIA (low) — warn, watch
[5] I/O counters      ── retries|timeouts > 0 ──▶ MEDIA or LINK
[6] kernel log        ── medium error + LBA ──▶ MEDIA (localise the LBA)
                      ── resets / disappear ──▶ LINK / POWER / HEAD
[7] symptoms          ── clicking / spin-down loops ──▶ HEAD
                      ── swap tests (cable/port/enclosure) separate LINK / POWER / BRIDGE
[8] driver inventory  ── third-party driver claims volume ──▶ aggravator: DRIVER   test native ro
[9] filesystem        (on the image only)
                      ── readable, consistent ──▶ NO ACTIONABLE FAULT
                      ── unreadable, no hardware signals ──▶ FILESYSTEM   repair the image copy
[10] nothing found    ──▶ INSUFFICIENT EVIDENCE   say so, do not guess
```

"Healthy" is not a verdict this tool can issue. SMART PASSED with clean counters is weak evidence
(many drives fail with no SMART warning), so the best outcome is *no actionable fault found*, with
the evidence that was and was not available.

### Confidence rules

Independent evidence sources: SMART, I/O statistics, kernel log, user symptom, filesystem probe.
Count sources, not attributes: pending, reallocated and uncorrectable are **one** source (SMART).
I/O statistics count as independent only if P0 (item 2) shows they carry real counters; until then
they are displayed but not counted.

| Confidence | Rule |
|---|---|
| **high** | ≥2 independent sources agree, no competing explanation |
| **medium** | one strong source (e.g. SMART pending > 0 alone), or two weak ones |
| **low** | one weak or circumstantial source |

Exit 10 requires class `MEDIA` at ≥ medium. A low-confidence `MEDIA` (e.g. a stable reallocated
count on an old drive) exits 0 with a warning, to avoid alarm fatigue.

### Fault classes and prescriptions

Root causes:

| Class | Trigger | Prescription | Do not |
|---|---|---|---|
| `MEDIA` | pending/uncorrectable > 0, rising reallocated, medium errors with LBA | image now, then mount the image read-only | mount the device; run fsck on it |
| `HEAD` | clicking (symptom), timeouts, device disappears, resets | power off, professional recovery | retry, spin it up again |
| `LINK` | resets correlating with port/cable, works elsewhere | swap cable/enclosure/port, retest | image through the suspect bridge |
| `POWER` | resets under load, spin-downs | powered hub, direct port | use a bus-powered hub |
| `BRIDGE` | SMART hidden, weird capacity, UAS quirks | swap enclosure, retest | conclude the disk is dead |
| `FILESYSTEM` | no hardware signals, mount/fsck fails | repair a **copy of the image**, then copy files | repair in place |
| `UNKNOWN` | no usable signals | state it; ask for the next test | invent a verdict |

`LINK` / `POWER` / `BRIDGE` / `HEAD` cannot be separated by logs alone; the swap-test symptoms
decide. Without them the tool reports the group with `low` confidence and names the cheapest test.

Aggravators (modify the advice, never the root cause):

| Aggravator | Trigger | Effect |
|---|---|---|
| `DRIVER` | third-party FS driver claims volume | disable/unmount driver; native ro mount only |
| `SMR` | model on SMR list | warn about long rebuild times |
| `ENCRYPTED` | firmware / FileVault / BitLocker detected | hand off; passphrase needed |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | no actionable fault found (warnings may apply) |
| 10 | media risk — image before anything else |
| 11 | failing — power off, professional recovery |
| 12 | bridge/link/power suspicion — swap and retest |
| 13 | filesystem only — repair the image |
| 20 | insufficient evidence |
| 21 | could not collect: permission denied (root / FDA) |
| 30 | tool error (missing dependency, collector failure) |

**Precedence when several apply:** 11 > 10 > 12 > 13 > 20 > 0. The code reports the most severe;
all findings appear in the JSON `causes` / `aggravators`. 21 and 30 are returned only when no
verdict can be formed; otherwise they are reported as signal statuses.

---

## 6. CLI

```
disktriage list                      # devices, one health line each
disktriage guard                     # hold mounts for new/attached disks; run BEFORE plugging in
disktriage triage <disk>             # decision tree; --json; --symptom/--tried flags
disktriage image <disk> --to <file>  # ddrescue wrapper: mapfile, resume, verify; --dry-run prints the command
disktriage inspect <image>           # inspect the IMAGE read-only (native mount, or ntfs-3g tools for NTFS)
disktriage copy <image> --to <dir>   # hashed copy + manifest; volume-level damage report
disktriage check                     # permissions & tooling self-test
```

Properties:

- `triage` never mounts, never writes (except the local history snapshot, which is optional), and
  works with no FDA.
- `image` is the only FDA-gated command. It requires a triage **attempt** for the device; an
  inconclusive result (exit 20, SMART hidden) does not block imaging, because that is exactly when
  imaging advice matters. `--override` skips the check explicitly. `--dry-run` prints the exact
  `ddrescue` command, and is the default in the first release.
- `UNSUPPORTED` media (SD, flash, NVMe) do **not** block imaging: classification and action are
  separate. The tool shows a caveat that no health classification applies.
- **Source identity is confirmed before the first read.** It prints model, serial and size and
  requires typing the last four characters of the serial (`--confirm-serial` for scripts), because
  `disk4` today may be `disk6` tomorrow.
- `list` labels unsupported media "triage not applicable"; it never shows a health line for
  devices the classifier does not cover (notably internal NVMe).
- `inspect` accepts images only — not `/dev/*`.
- `copy` is a thin wrapper (see §8) that reports damage at volume level in v1; it may be cut if
  `ditto` + manifest proves enough.
- `--json` on every command; human output is a rendering of the same struct.
- Progress on stderr, verdict on stdout, so it composes in scripts.

---

## 7. FDA onboarding

Full Disk Access is a TCC privacy permission (not a firewall). It gates raw block devices, applies
to root, never prompts, and is evaluated at process launch. A root launchd daemon without the grant
is denied — proven on this case.

### Process identity — decide in P0/P2, not P4

TCC attributes access to the *responsible process*. A CLI run from Terminal is attributed to
Terminal, so a signed `.app` only helps if the app (or a helper it owns) is what does the read.
Options:

| Option | How | Trade-off |
|---|---|---|
| A. CLI in Terminal | user grants FDA to Terminal / iTerm | simplest; broad privilege for the whole terminal |
| B. `.app` launcher | signed bundle hosts the CLI; stable `CFBundleIdentifier` | grant survives updates; CLI ergonomics suffer |
| C. Helper | signed tool via launchd/SMAppService with FDA; CLI talks over XPC | most robust and least privilege; heaviest |

v1 default is A with an explicit warning, unless P0 shows it is unworkable. P0 must also verify
that `ddrescue`, as a child process, inherits the grant under each option.

### State machine

```
UNKNOWN ──probe(512B read)──▶ GRANTED ──probe──▶ VERIFIED
   │                              │
   └──────────────▶ DENIED ◀──────┘
                     │
                     ├─ print exact binary path to add
                     ├─ deep-link Settings pane
                     ├─ "relaunch required — the grant applies at launch"
                     └─ re-probe on next run (never cache across launches)
```

Deep link:
`open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"`
(verify across macOS releases).

### Rules

- **Never claim granted.** Probe with a real read every run; a stale flag is worse than no flag.
- **Probe without touching the suspect disk.** Read 512 B from the *internal* disk's raw node;
  fall back to the target only if that is not possible. (Verify in P0.)
- **Distinguish the failure.** `EPERM` (TCC / FDA) and `EACCES` (Unix permissions → needs sudo)
  are different states with different instructions. (P0: confirm which errno TCC returns.)
- **Degraded mode is first-class.** Without FDA: complete triage, render the verdict, and mark
  imaging as blocked with the reason. The diagnosis does not need permission.
- **Name the right binary.** If run from a terminal, that terminal app needs the grant — a footgun
  the tool must state explicitly, including that it is a broad grant.
- **Signed identity** (options B/C). Stable `CFBundleIdentifier` + signature so the grant
  survives updates; ad-hoc dev builds are keyed by path+hash and lose the grant on every rebuild.
  Requires a paid Developer ID and notarization. The bundle ID is permanent, so settle the name (§12)
  before the first signed build.
- **MDM path documented**, not built: PPPC payload with `kTCCServiceSystemPolicyAllFiles` for fleets.

### Self-test (`disktriage check`)

| Check | Expectation |
|---|---|
| running as root | yes/no |
| raw device read | GRANTED / DENIED (EPERM vs EACCES) |
| removable volume file access | GRANTED / DENIED |
| `smartctl` present | version |
| `ddrescue` present | version |
| third-party FS drivers | list |
| unified log readable | yes/no |
| mount guard available | yes/no |

---

## 8. Imaging & inspection

### Mount guard

`diskarbitrationd` automounts at plug-in, which violates principle 1 before the tool runs.

- `guard` registers a DiskArbitration mount-approval callback and dissents for target devices.
  Intended use: start it **before** connecting the drive.
- If the volume is already mounted: `diskutil unmountDisk` with a hard timeout. If that hangs
  (third-party driver stuck in a retrying read), say so and instruct a physical disconnect, then
  reconnect with `guard` running.
- **Measured (P0 row 5):** the dissent does stop the third-party NTFS driver's *mount*, but not its
  *probe*, which runs first and reads the volume. For a disk whose first sectors are already
  failing, the probe itself can stall. A stronger guard is to suspend `diskarbitrationd`
  (`SIGSTOP`) for the whole session, which prevents both probe and mount; while it is stopped,
  `diskutil` hangs, so collection uses `ioreg` only. **UNVERIFIED** until P0 phase C. Where neither
  is acceptable, use the Linux rescue path (the only host on which macOS never sees the disk).
- `hdiutil attach` for inspection always uses `-nomount`, then an explicit native mount, so a
  third-party driver cannot claim the image volume.

### Imaging

- **Backend:** `ddrescue` as a subprocess (GPL — invoking is fine; bundling requires compliance).
- **Always write a mapfile.** It is what makes pass 2 and "which file is damaged" possible.
- **Resume by default**, but only after validating that the mapfile and image belong to this device
  (size and serial recorded alongside). Refuse to write into an existing file that has no matching
  mapfile.
- **Destination checks:** not on the source disk; enough free space for the full size; a filesystem
  without a 4 GB file limit; writable.
- **Source identity confirmation** (§6): model + serial + size shown, last four of the serial typed.
- **Prevent sleep:** hold an IOPMAssertion / `caffeinate` for the duration. A sleeping Mac drops
  the drive mid-image.
- **Guardrails use ddrescue's own controls** instead of reimplementing them: `--max-read-rate`,
  `-T/--timeout`, `-e` (max errors), plus the process watching for the device disappearing. A drive
  that dies mid-image is a normal case, not an edge case.
- **Survive bus drop-outs:** cheap USB bridges drop off the bus mid-read. Use `-O/--reopen-on-error`
  so ddrescue reopens and resumes instead of aborting, and `-K/--skip-size` to step past a region
  that provoked the drop. Confirm exact semantics on macOS in P0 (item 9).
- **No SMART polling while imaging.** It competes for the bus and can wedge a failing drive. Poll
  temperature only between passes, or not at all.
- **Two passes:** `-n` first (fast sweep), then `-r3` (scrape). Measured here: pass 2 hit ~200 B/s
  and would have needed 14 more hours for 9.9 MB.
- **Pass-2 stop rule (a rule, not a sentiment):** stop and report when the marginal yield over the
  trailing 10 minutes is < 0.01% of device size **and** the projected remaining time is > 2× the
  time elapsed. Thresholds are tunable; the measured ~200 B/s case is the reference trigger. On
  stop, print what remains unread and the exact command to resume.
- **Platform quirks to verify (P0/P3):** ddrescue direct-I/O behaviour and sector-size detection on
  macOS, `/dev/rdiskN` vs `/dev/diskN`.
- **Measured on macOS 27.2 (P0 phase B):** `ddrescue -d` (direct I/O) fails with "Direct disc
  access not available" and must not be used. Use `/dev/rdiskN`; `-b` equals the device block size;
  `-O` and `-K` are accepted; four 16 MiB images (plain, `-b 4096`, `-n -O -K`, buffered node) were
  byte-identical to a `dd` reference. Reopen-on-bus-drop behaviour is UNVERIFIED.
- **ETA** is derived from device size and measured bus speed, shown as a range, not a promise.

### Inspection

- **APFS / HFS+ / exFAT / FAT:** `diskutil image attach --noMount --readOnly` (or
  `hdiutil attach -readonly -nomount`), then an explicit native read-only mount. Never a writable
  third-party driver.
- **NTFS:** no native mount exists on macOS 27.2. Inspect the image with the ntfs-3g userspace tools
  (`ntfsinfo`, `ntfsls`, `ntfscat`): read-only, no mount, no root, no FDA, tens of milliseconds on a
  64 MiB image (`docs/ntfs-spike.md`). Never a mount of the image through a third-party driver.
- **Whole-disk images:** the ntfs-3g tools have no offset option. Extract the partition with
  `dd skip=` (least bad: byte-identical, no kernel path) or attach with `diskutil image attach
  --noMount --readOnly`. Cluster numbers are **volume-relative**: subtract the partition offset in
  every mapfile-to-cluster conversion. Raw images may still be probed by DiskArbitration; testing
  attach with a third-party driver installed is an explicit P3 test, not an assumption.
- **Boot-sector damage (the MiNaH case):** the ntfs-3g tools do **not** fall back to the backup boot
  sector; every command fails. **Verified on synthetic images (P0 row 11, `docs/ntfs-spike.md`):** on a
  **working copy** of the image, never the original, and only when explicitly requested, copy the
  backup boot sector over the primary with `dd conv=notrunc`, then re-open. The backup is the last
  sector of the **partition**: `backup_offset = partition_offset + partition_length_bytes - 512`
  (take the length from the MBR/GPT, not from the BPB `total_sectors`, which `mkntfs` leaves one
  sector short; the disk's last sector is wrong). Before copying, validate the backup: OEM ID
  `"NTFS    "`, bytes per sector in {512, 1024, 2048, 4096}, power-of-two sectors per cluster, `55 AA`;
  afterwards confirm with `ntfsinfo`. Do **not** use `ntfsfix` for this: it also sets the dirty flag
  and empties `$LogFile`. If the backup is bad too, report that the volume cannot be restored and
  fall back to a volume-level damage report. Not tested: Windows-formatted volumes, 4Kn sectors, the
  real MiNaH backup sector (the old image was deleted).
- **Failure behaviour to design around:** metadata damage fails loud (nonzero exit), but *data*
  damage is silent (exit 0, correct length, zero bytes) and `ntfsls` exits 0 on a partial listing.
  So every `inspect` and `copy` output carries mapfile-derived damage notes next to it.
- Unreadable regions of the image are zero-filled. That is *not* an I/O error, so inspection and
  copy must consult the mapfile to know which data is real.

### Copy and damage reporting

Two facts shape this. Unreadable regions are zero-filled in the image, and that is not an I/O error.
And a copy of a zero-filled hole hashes perfectly, so hash equality proves only that the copy
matches the image, **not** that the image matches the platter.

- **Baseline, always: volume-level reporting.** `copy` reads the mapfile and reports, e.g., "447
  unreadable extents, 11.4 MB". The manifest records `damage.scope = "volume"`. Where per-file
  attribution is unavailable (see below), it says so and makes **no per-file integrity claim**
  (`attribution: "none"`).
- **Hash while copying.** SHA-256 of what was read from the image and of what was written. This
  proves the write landed and the copy is faithful to the image. It says nothing about whether the
  image was faithful to the disk, and the output states that.
- **Per-file attribution is a capability, never implied.** It requires real extent mapping.
  - **NTFS (v1):** convert each bad extent from the mapfile to a volume-relative cluster range
    (subtract the partition offset, divide by the cluster size) and ask `ntfscluster -c <range>`
    which inode owns it, or, better, do it in **one pass**: `ntfscluster -c 0-(nr_clusters-1) -v` dumps
    every inode's VCN/LCN runs at once (11 ms / 10.7 KB on 64 MiB, 145 ms / 1.78 MB on a 10,001-inode
    volume) and the bad extents are intersected locally, which is exact. It names data files, and
    names `$MFT` / `$INDEX_ALLOCATION` metadata verbatim. Do not merge extents into one min-max span
    (it names files in the good gaps). Guard the pass with a 120 s timeout and a 200,000-run cap.
    Fallback, one `ntfscluster -c <range>` per extent (cost about 6 ms plus 2 us per inode, 447
    extents = 5.9 s on the test image), capped at `min(200, 30 s / measured ms-per-call)`; beyond the
    cap, report volume level and say so. Timings above 10,001 inodes are extrapolated (UNVERIFIED).
  - **Not available** when the damage hits `$MFT` (the volume will not open at all), or when the
    boot sector is damaged and not restored: report volume level and state why.
  - **Other filesystems:** `F_LOG2PHYS_EXT` on a mounted image, only where P0 shows the native driver
    supports it (HFS+/APFS: still open); otherwise volume level.
  - When active, each file is `integrity: intact | overlaps-bad-extent | metadata-damaged` with
    `attribution: "ntfscluster"` (or `"extent-map"` for another mapper).
- **No flag-everything fallback.** If mapping is unavailable, make no per-file claims. Marking every
  file `unknown` would be indistinguishable from not reporting.
- Decision for v1: volume-level report always, plus `ntfscluster` per-file attribution for NTFS when
  the volume opens. An own NTFS parser is deferred (see §9) and only reconsidered if the tools prove
  unusable on real damage.

### Repair hand-off

- `FILESYSTEM` prescribes repair of a **copy of the image**, never the original image or device.
- Native tools exist for HFS+/APFS/FAT/exFAT (`fsck_*`). For **NTFS there is no native repair**, so
  the tool prints a hand-off (`ntfsfix` / `chkdsk` against a copy, or a data-recovery tool) and
  does not run it. The only NTFS write the tool may perform is the explicit boot-sector restore on
  a working copy described under Inspection.

---

## 9. Open decisions

| Decision | Recommendation | Needed by |
|---|---|---|
| Implementation language | Swift for macOS collectors (IOKit, DiskArbitration, TCC, signing); the JSON `SignalSet` + shared fixtures keep a later Linux port independent of the language | before P1 |
| Process identity for FDA | A (Terminal) by default; revisit after P0 attribution results | end of P0 |
| Final name | choose before any signed build (bundle ID is permanent) | before P4 |
| Per-file damage attribution | **Decided for v1: volume-level report always, plus `ntfscluster` per-file attribution for NTFS** (spike: `docs/ntfs-spike.md`). An own NTFS parser (3–5 d basic, 1–2 weeks robust) is deferred; reconsider only if the tools fail on real damage. Fixes the manifest schema | before P1 |
| NTFS inspection dependency | **ntfs-3g userspace tools** as a GPL subprocess on images (not bottled; core formula is Linux-only; tap variant needs macFUSE), built from the upstream tarball with `--disable-ntfs-3g`. macFUSE rejected as a dependency | before P3 |
| Keep `copy`? | decide after P3; may reduce to `ditto` + manifest | P3 |

---

## 10. Build phases

Estimates were roughly doubled after review.

| Phase | Deliverable | Est. |
|---|---|---|
| **P0 gate** | Prove on hardware (see decision table below). Output: a go/no-go note per premise, plus a decision on process identity and language | 1 d |
| **P1** | `SignalSet` schema (status per section, nullable counters, symptoms, version), classifier with confidence/precedence/trend rules, `list` / `triage`, collector hardening (timeouts), golden fixtures | 4–5 d |
| **P2** | `check` + FDA state machine + degraded mode + process-identity implementation | 2–3 d |
| **P3** | `guard`, `image` (dry-run first), `inspect`, `copy` with hashing and volume-level damage report; explicit whole-disk MBR/GPT image-attach tests | 4 d |
| **P4** | Signed + notarized app/helper (needs Developer ID account) | 2 d + enrolment |
| **P5** | Linux collector | 2–3 d |

`check` and the FDA flow (P2) precede `image` (P3) because imaging depends on them.

### P0 decision table

Every question has a pre-committed branch, so P0 produces a decision rather than a finding. The
earlier question "was the MiNaH SMART data collected on macOS?" is closed: it came from Linux.

| # | Question | If yes | If no |
|---|---|---|---|
| 1 | Does `smartctl -d sat` work over USB on current macOS / Apple Silicon, and does opening the device trip TCC or need root? | Triage stays permission-free; FDA is only an imaging concern | **TCC/root is the cause:** FDA moves onto P2's critical path. **Bridge is the cause:** publish a per-bridge known-good list; `BRIDGE` becomes the common path and the confidence rules lose a source |
| 2 | Does `ioreg` expose real retries/timeouts for USB disks? | Genuine third independent source for §5 | Do not count I/O stats as independent; display only; recalibrate confidence rules |
| 3 | Does the unified log retain medium errors with LBAs, and for how long? | The no-SMART path keeps its strongest signal; record the window in `log.window_hours` | Product value drops materially: reduce to symptoms + imaging advice, and reconsider shipping triage before `image` |
| 4 | Does `F_LOG2PHYS_EXT` work on a native read-only mount? **NTFS: answered no (A2: no native NTFS mount helper exists).** Still open for HFS+/APFS | Per-file attribution via ioctl is viable for that filesystem | NTFS attribution comes from `ntfscluster` (§8); other filesystems: volume-level reporting |
| 5 | Does a DiskArbitration mount-approval dissent block third-party driver mounts? | `guard` is the enforcement mechanism | Principle 1 is advisory only: pick another mechanism (e.g. disable-driver instructions) or downgrade the principle honestly |
| 6 | Does a `ddrescue` child inherit the TCC grant under option A (Terminal)? | Option A survives | Option B or C is required; P2 becomes the largest phase, not P3 |
| 7 | Does TCC return a different errno (`EPERM`) from Unix permissions (`EACCES`)? | State machine as specified | Collapse to a single "denied" state and show both remedies |
| 8 | Does a raw read of the internal disk work as an FDA probe? | Probe off the suspect disk | Probe the target with one bounded, time-limited read |
| 9 | ddrescue on macOS: direct I/O, sector size, `/dev/rdiskN`, `-O`, `-K` behave as documented? | Wrapper defaults as in §8 | Adjust wrapper defaults and document the workarounds |
| 10 | Do `diskutil` / `smartctl` hang on a failing disk, and do timeout + kill work (uninterruptible I/O)? | Collectors as designed | Treat the stuck collector as evidence (`timeout` = unresponsive), abandon it without waiting, never block the CLI |
| 11 | On a real MiNaH-style image (boot sector unreadable), does restoring the backup boot sector on a working copy let the ntfs-3g tools open the volume, and how long does `ntfscluster` take across a realistic number of bad extents on a large volume? | Boot-sector restore stays in §8; set the extent cap from the measured time | Report volume-level only for boot-sector damage and say why; consider an own parser for the boot-sector/MFT-mirror cases |

Schema impact: items 3 and 4 touch fields (`log.window_hours`, manifest `attribution`). Resolve them
before the P1 schema freeze. If item 1 fails because of TCC, or item 6 fails, the FDA design
becomes the main engineering work and P2 grows.
P2 grows.

---

## 11. Test strategy

Golden fixtures — recorded `SignalSet` JSON replayed against the classifier, asserting class,
confidence, aggravators, and exit code. Fixtures must include signal *statuses* (denied, timeout),
not only values.

| Fixture | Expected |
|---|---|
| **MiNaH** — pending 131, reallocated 14, medium error @ LBA 2048, third-party NTFS driver | `MEDIA` (high), `DRIVER` aggravator, exit 10 |
| bridge hides SMART, no other signals | `BRIDGE` low + `UNKNOWN`, exit 12 or 20 per rules |
| bridge hides SMART, kernel log shows medium error + LBA | `MEDIA` (medium), exit 10 — SMART absence does not hide the log evidence |
| clean counters, filesystem reads fine | no actionable fault, exit 0 (not "healthy") |
| stable reallocated=5, no pending, no history | `MEDIA` low, exit 0 with warning |
| reallocated rising vs snapshot (**synthetic history**) | `MEDIA`, exit 10 |
| no hardware signals, mount/fsck fails | `FILESYSTEM`, exit 13 |
| resets + `clicking` symptom | `HEAD`, exit 11 |
| collectors all timed out | `UNKNOWN`, exit 20 (statuses `timeout`, not zeros) |
| SMART denied, not root | exit 21 |
| NVMe / flash / SD device | `UNSUPPORTED`, exit 20; `image` still offered with a caveat |
| two faults (MEDIA + BRIDGE suspicion) | precedence: exit 10, both in JSON |

Fixture sources: the MiNaH case is real; the rest are synthetic and encode our assumptions. The
MiNaH fixture has no history (first sight of the drive); any fixture with history is labelled
synthetic.
Mitigation: `triage --record` writes a redacted SignalSet (serial hashed) so real captures from
other drives replace synthetic ones over time.

Acceptance test for P1 is the day-one transcript below: given the MiNaH fixture, the renderer must
produce it. Timestamps render in UTC unless `--local` is passed, so the test is timezone-stable.

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| SMART over USB doesn't work on modern macOS | **Measured: not reachable via smartctl through the Seagate bridge on macOS 27.2 (P0 row 1).** The no-SMART path (kernel log, ioreg Retries/Errors, symptoms) carries triage; a second, unrelated bridge fails identically, so it is macOS-wide rather than bridge-specific |
| USB-SATA bridges hide SMART entirely | Explicit `BRIDGE` branch; publish a known-good bridge list; never fake a verdict |
| TCC behaviour changes between macOS releases | Probe every run; keep the permission layer one module |
| Granting Terminal FDA is a broad privilege | State it explicitly; offer the app/helper options |
| Tool blamed for a disk dying during imaging | Guardrails, explicit "this can finish the drive off" consent, dry-run first |
| Tool says "safe" to someone about to lose data | `UNKNOWN` is first-class; never infer health from a missing signal; no "healthy" verdict |
| Tool hangs with the disk | Collector isolation, hard timeouts, uninterruptible-I/O handling |
| `copy` launders damage into "verified" files | Volume-level damage report; per-file claims only with real extent mapping; state what hashing does and does not prove |
| Alarm fatigue from benign reallocated sectors | Trend rules; low-confidence results exit 0 with a warning |
| Mac sleeps during a 3–4 h image | IOPMAssertion / `caffeinate` |
| Pass 2 burns hours for negligible yield | Quantified stop rule (§8) |
| USB bridge drops off the bus mid-image | `-O` reopen-on-error, `-K` skip-size |
| Imaging the wrong device after a `diskN` renumber | Serial-confirmation prompt before the first read |
| Unsupported media treated as "nothing to do" | `UNSUPPORTED` blocks classification only; imaging stays available |
| Mount at plug-in before the tool runs | `guard`, documented workflow |
| Driver probe reads at plug-in can stall on a failing disk; a dissent does not stop them | Suspend `diskarbitrationd` for the session (UNVERIFIED, P0 phase C) or use the Linux rescue path; say that a probe read may already have happened |
| Resuming onto the wrong image / wrong disk | Validate mapfile + image against device size and serial |
| SMR drives image badly | Detect and warn; note long rebuild behaviour |
| Firmware-encrypted drives (WD/Seagate) | Out of scope, detect and hand off |
| APFS/FileVault volumes | Read-only attach works; encryption needs a passphrase, prompt safely |
| No native NTFS repair | Hand-off only; documented exception to principle 4 |
| No native NTFS reader on macOS 27.2 | ntfs-3g userspace tools on the image (GPL subprocess, source build); no macFUSE, no kernel extension |
| Boot sector damaged (the MiNaH case): the ntfs-3g tools do not fall back to the backup | Restore the backup boot sector on a working copy only, explicitly requested; UNVERIFIED (P0 row 11) |
| Damage hits `$MFT`: the volume will not open, so no file-level attribution | Volume-level report that states why |
| `ntfscluster` takes one range per invocation | Cap on extents, fall back to volume level beyond it; large-volume timing UNVERIFIED |
| Data damage is silent (exit 0, zero bytes); `ntfsls` exits 0 on partial listings | Mapfile-derived damage notes beside every `inspect` / `copy` output |
| SSD / NVMe / flash misclassified as HDD | Media-type check; `UNSUPPORTED` verdict |
| GPL | `ddrescue` as subprocess; comply if bundled |

---

## 13. Naming & distribution

The original name, "DiskDoctor", collides with Norton Disk Doctor and an Amiga tool, which is why
it was never committed to. Decision (2026-11-06): renamed to `disktriage`. Known overlap: three
unrelated small GitHub repos are named DiskTriage; github.com/disktriage is unclaimed; Homebrew has
no formula of that name. Bundle identifier is still not fixed and must be decided before the first
signed build, since the bundle identifier is permanent for TCC.

Distribution: Homebrew tap first, signed `.app` wrapper later. Triage depends on `smartctl`
(smartmontools) and imaging on `ddrescue`; the formula declares both. NTFS inspection depends on
the ntfs-3g userspace tools, built from the upstream tarball with `--disable-ntfs-3g` (no FUSE).
Homebrew's core formula is Linux-only and the tap variant requires macFUSE, so the formula builds
from source or ships a pinned static build (GPL: comply if bundled). A bootable Linux rescue image
is the ultimate answer to TCC — it sidesteps the permission model entirely — but is a separate
product, and awkward on Apple Silicon.

---

## 14. Revision history

**v3.5 (2026-11-07), after P0 row 11 (synthetic):**

- Boot-sector restore is verified: `dd` the partition's last sector over its first on a working copy,
  with the offset formula and validation checks in §8; `ntfsfix` rejected (dirty flag, emptied log).
- NTFS per-file attribution is a single `ntfscluster -c 0-(N-1) -v` pass intersected locally, not one
  subprocess per extent (which is only the capped fallback).

**v3.4 (2026-11-07), after P0 phase C:**

- Recorded the real kernel-log medium-error format and ioreg behaviour on the failing drive (§4):
  `Errors` moves, `Retries` does not; one unreadable read blocks about 45-50 s.
- P0 row 11 (boot-sector restore) is answered on synthetic images (see v3.5); the real backup sector
  is untested because the earlier MiNaH image was deleted.

**v3.3 (2026-11-07), after P0 phase B and row 5:**

- Principle 1 narrowed to "never mount": a DiskArbitration dissent blocks the mount but not the
  third-party driver's probe reads; a `diskarbitrationd` suspend is the stronger guard (UNVERIFIED).
- Measured: SMART unreachable via smartctl through the Seagate bridge; ioreg exposes real
  Retries/Errors counters but no timeouts; `ddrescue -d` unavailable on macOS.
- Fixed a misplaced table row: P0 row 11 had been inserted into the exit-code table.
- A second, unrelated USB bridge (VLI + Samsung SSD) fails smartctl identically: SMART over USB is
  unavailable on this macOS, not bridge-specific. Media type over USB is `unknown`.

**v3.2 (2026-11-06), after P0 phase A and the NTFS spike:**

- macOS 27.2 has no native NTFS mount helper: principle 4 and §8 now use the ntfs-3g userspace
  tools on the image (no mount, no FUSE); macFUSE rejected.
- Per-file damage attribution for NTFS via `ntfscluster` replaces "volume-level only" as the v1
  design; an own parser deferred.
- Boot-sector damage (the MiNaH case) gets a planned, unverified restore-on-a-copy path (P0 row 11).
- §7/P0 results recorded in `docs/p0-runbook.md`: EPERM (1) = TCC denied, EACCES (13) = TCC passed;
  the grant follows the app and is lost when the bits change; probes use 4096-byte reads.

**v3.1 (2026-11-06), naming:**

- Renamed the product to `disktriage`; the CLI, library target and test runner follow. No plan
  content changed beyond the name (§13).

**v3 (2026-11-06), after second review:**

- P0 questions now have pre-committed "if yes / if no" branches (§10).
- Per-file damage attribution decided: volume-level reporting in v1; no flag-everything fallback;
  hashing claims stated precisely; NTFS runlist parser planned as v1.1.
- `UNSUPPORTED` classifies nothing but no longer blocks imaging; `list` does not imply coverage.
- SMART-over-USB reframed from "biggest unknown" to a verify item; the real question is whether
  device-open trips TCC. Noted that MiNaH SMART came from Linux.
- Confidence: count sources, not attributes; I/O stats count only after P0 validates them.
- Appendix: removed invented history and the "three sources" overclaim.
- Added pass-2 stop rule, `-O`/`-K`, serial confirmation on `image`, hashing in `copy`, and
  partition-level image-attach tests.

**v2 (2026-11-06), after review:**

- Removed the loss-size prediction ("tens of KB to a few MB"): the pending count understates the
  damaged area (131 sectors ≈ 67 KB vs ~9.9 MB unread in the reference case).
- Principle 2 made honest about tool dependencies and root.
- `SignalSet`: versioned, per-section status, nullable counters, symptoms, history, UTC; removed
  `bitflips`/`no_dma`.
- Added mount guard, collector hardening, and allow-listed read-only commands.
- Classifier: causes vs aggravators; defined confidence; trend rule for reallocated; no "healthy"
  verdict; exit-code precedence; split 20/21/30.
- `image`: triage attempt (not success) required; dry-run first; ddrescue native guardrails; mapfile
  validation; destination checks; sleep prevention; no SMART polling mid-image.
- `copy`: per-file integrity flags; minimal damage localisation pulled forward from v2.
- NTFS repair made an explicit hand-off.
- FDA: process-identity options decided in P0; errno distinction; probe off the suspect disk.
- Scope narrowed to external HDDs; open decisions (language etc.) listed.
- Phases reordered (`check`/FDA before `image`), estimates doubled, P0 expanded to a checklist.
- Fixtures expanded; `--record` added for real captures.

---

## Appendix — acceptance transcript

Rendered from the MiNaH fixture: first sight of the drive, so there is no history snapshot and no
trend line.

```
$ disktriage triage disk4

DEVICE   disk4                              whole disk, 298.1 GiB
MODEL    WDC WD3200BJKT-75F4T0
SERIAL   WD-WX0123456789
BUS      USB — generic SATA bridge (SAT passthrough: partial)
AGE      4,531 power-on hours · 14 reallocated events

SMART ─────────────────────────────────────────────────────────────
  overall            PASSED            ← threshold-based; ignore on its own
  pending sectors    131               ← at least 67 KB the drive cannot currently read
  reallocated        14
  uncorrectable      0
  raw read errors    21,545

ERROR SIGNALS ─────────────────────────────────────────────────────
  IORegistry         retries 1,204 · timeouts 3
  unified log        medium error, LBA 2048  (6 occurrences, 23:51Z–00:12Z)

FILESYSTEM DRIVERS ────────────────────────────────────────────────
  /Library/Filesystems/iboysoft-ntfs.fs    ← third-party, claims NTFS volumes
  NTFS inspection: ntfs-3g tools on the image (no mount)

DIFFERENTIAL ──────────────────────────────────────────────────────
  1. MEDIA DEGRADATION                          confidence: HIGH
     pending=131, reallocated>0, medium errors pinned to one LBA
     (two independent sources agree: SMART and the kernel log;
     I/O statistics corroborate).
     That LBA (2048) is the NTFS boot sector — every mount reads it
     first, which is why the volume dies before it can say anything.

  2. ENCLOSURE / LINK                           confidence: LOW
     3 timeouts could be the bridge, but pending sectors are
     drive-internal. The bridge cannot explain them.

  AGGRAVATING FACTOR
     DRIVER HANG                                confidence: MEDIUM
     A third-party FS driver may block on a retrying read, which makes
     a slow disk look dead.

VERDICT
  The disk is degrading, not dead. The pending-sector count is a floor,
  not an estimate: the real extent of loss is unknown until the device
  has been imaged. Do not mount it again.

NEXT  (~3–4 h, estimated from size and bus speed)
  disktriage image disk4 --to /Volumes/Scratch/minah.img
  (you will be asked to type the last four of the serial: 6789)

THEN
  disktriage inspect minah.img      # read-only, ntfs-3g tools on the image, no mount, no third-party driver
  disktriage copy   minah.img --to ~/Archive   # hashed copy + volume-level damage report
```

Degraded (no FDA):

```
$ disktriage image disk4 --to ...
  ! raw device access denied (TCC)
    Triage completed without it: verdict still MEDIA.
    Imaging needs Full Disk Access for the process that runs it
    (Terminal, if you launched this from Terminal).
    → System Settings open · relaunch required (grant applies at launch)
```
