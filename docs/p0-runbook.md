# P0 bench runbook — disktriage

How the human answers the 10 P0 questions in [the plan](../diskdoctor.md) §10 on
real hardware, in an order that protects the dying drive. P0's output is one
recorded decision per row, not a pile of observations.

**Every command here is read-only with respect to every device.** The only writes
are to `captures/` (a file, never a device node) and to the scratch volume when a
test volume is created. `captures/` is gitignored because it holds serial numbers;
only redacted fixtures are ever committed.

## 0. Bench inventory

| Role | What it is | Rule |
|---|---|---|
| Host | this Mac (Apple Silicon or Intel — record which in §Results) | one host for all phases |
| Control disk | healthy spare HDD | Phase B only; readable, expendable |
| Scratch | volume with ≥ 8 GiB free, **not** on the control disk | ddrescue destinations, test volumes |
| Enclosure E1 | USB-SATA bridge #1 | Phase B; record VID/PID |
| Enclosure E2 | USB-SATA bridge #2, different chipset | Phase B; record VID/PID |
| MiNaH | WD3200BJKT, 131 pending sectors, already imaged once | **Phase C only, last.** Dying: every read is a cost |

## 1. Prerequisites — do not start Phase A until all pass

| # | Item | Command | Pass condition |
|---|---|---|---|
| P1 | Xcode licence | `sudo xcodebuild -license accept` then `xcodebuild -version` | prints `Xcode <ver>`; `xcodebuild -checkFirstLaunchStatus` exits 0 |
| P2 | Homebrew tools | `brew install smartmontools ddrescue` | `smartctl --version`, `ddrescue --version` both print a version |
| P3 | Tool help kept as evidence | `mkdir -p captures && smartctl --help > captures/smartctl-help.txt; ddrescue --help > captures/ddrescue-help.txt` | files non-empty; **reconcile every `UNVERIFIED` flag below against them before use** |
| P4 | No `timeout` assumption | `TO 2 sleep 10; echo $?` with the function from §2 | prints `124` |
| P5 | Scratch space | `df -h /Volumes/<scratch>` | ≥ 8 GiB avail; filesystem is not FAT32 |
| P6 | Third-party NTFS driver state | `diskutil listFilesystems; ls /Library/Filesystems /Library/Extensions` | record exactly what is installed (see §Results) |
| P7 | Terminal identity | note which terminal app runs the bench, and its version | needed for every FDA statement |
| P8 | Capture dir | `mkdir -p captures` | exists; `git status --short` shows nothing (it is ignored) |

Known on the reference machine: `diskutil listFilesystems` lists a third-party
`iboysoft_NTFS` personality, `/Library/Extensions` contains `ms_ntfs.kext`,
`CIJUSBLoad.kext`, `SoftRAID.kext`, and no native `mount_ntfs` binary exists
(`man -w mount_ntfs` finds no entry). Record the same three facts if they hold at
the bench: they decide row 4 before any drive is touched.

## 2. Timeouts — mandatory on every collector

macOS does not ship `timeout` on most releases (this build does have
`/usr/bin/timeout` — do not rely on it, and it is absent on older releases), and
`gtimeout` needs `brew install coreutils`. Use a `perl` wrapper with a
**process-group kill** (a plain `kill` leaves the wedged child behind, which is
exactly the P0 row-10 case):

```sh
TO() { perl -e 'my $s=shift; my $p=fork; die $! unless defined $p; if(!$p){setpgrp(0,0);exec @ARGV;exit 127} $SIG{ALRM}=sub{kill "TERM",-$p;sleep 1;kill "KILL",-$p;waitpid($p,0);exit 124}; alarm $s; waitpid($p,0); exit($?>>8)' "$@"; }
```

Verified here: `TO 2 sleep 30` → `124`; a passing command keeps its own exit code.
`124` means **timeout**, and a timeout is evidence (`timeout` status), not zero.
Never read a status through a pipe — capture `$?` from `TO` itself.

## 3. The pre-committed branches (quoted from the plan, §10)

| Row | If yes | If no |
|---|---|---|
| 1 | "Triage stays permission-free; FDA is only an imaging concern" | "**TCC/root is the cause:** FDA moves onto P2's critical path. **Bridge is the cause:** publish a per-bridge known-good list; `BRIDGE` becomes the common path and the confidence rules lose a source" |
| 2 | "Genuine third independent source for §5" | "Do not count I/O stats as independent; display only; recalibrate confidence rules" |
| 3 | "The no-SMART path keeps its strongest signal; record the window in `log.window_hours`" | "Product value drops materially: reduce to symptoms + imaging advice, and reconsider shipping triage before `image`" |
| 4 | "Per-file attribution via ioctl is viable" | "Volume-level reporting in v1 (already decided); NTFS runlist parser planned for v1.1" |
| 5 | "`guard` is the enforcement mechanism" | "Principle 1 is advisory only: pick another mechanism (e.g. disable-driver instructions) or downgrade the principle honestly" |
| 6 | "Option A survives" | "Option B or C is required; P2 becomes the largest phase, not P3" |
| 7 | "State machine as specified" | "Collapse to a single \"denied\" state and show both remedies" |
| 8 | "Probe off the suspect disk" | "Probe the target with one bounded, time-limited read" |
| 9 | "Wrapper defaults as in §8" | "Adjust wrapper defaults and document the workarounds" |
| 10 | "Collectors as designed" | "Treat the stuck collector as evidence (`timeout` = unresponsive), abandon it without waiting, never block the CLI" |

---

## Phase A — Mac only, no external disk

Nothing is plugged in. Nothing here can touch MiNaH.

### A1 — Record the machine (no row; goes in §Results)

```sh
sw_vers; uname -m; system_profiler SPHardwareDataType | sed -n '1,25p'
xcodebuild -version; sw_vers -productVersion
system_profiler SPUSBDataType | head -40
```
Expect: OS name/version/build, `arm64` or `x86_64`, model identifier + chip,
Xcode version. Record all of it; the answer to row 1 is version-specific.

### A2 — Baseline: raw nodes, filesystems, driver inventory (row 4 pre-check)

```sh
ls -l /dev/rdisk*            # internal only, at this point
TO 20 diskutil list -plist   # syntax check; note AllDisksAndPartitions
TO 20 diskutil info -plist disk0 | grep -A1 -E 'MediaName|DeviceBlockSize|Size|BusProtocol|MountPoint|DeviceNode'
TO 20 diskutil listFilesystems
TO 20 ls -l /System/Library/Filesystems/ntfs.fs/Contents/Resources/
TO 20 man -w mount_ntfs; echo "mount_ntfs_man_rc=$?"
TO 10 smartctl --version; echo "smartctl_rc=$?"    # UNVERIFIED (tool not installed)
TO 10 ddrescue --version; echo "ddrescue_rc=$?"    # UNVERIFIED (tool not installed)
```
Expect: `crw-r----- root operator` on `/dev/rdisk*`; plist keys `MediaName`,
`DeviceBlockSize`, `Size`, `BusProtocol`, `MountPoint` (`""` = unmounted);
`listFilesystems` shows native personalities plus any third-party one; both
tools print versions (P2 installed them before Phase A).
Record: whether a native NTFS **mount helper** exists at all. If
`mount_ntfs_man_rc` is non-zero and no helper is in `Resources/`, the native
read-only NTFS mount that row 4 assumes does not exist on this build — record it
now, and row 4 is answered "no" at B4 by absence, not by a failed ioctl.

### A3 — errno probe: EPERM (TCC) vs EACCES (Unix) — rows 7 and 8

Three states. Run the same 512 B read of the **internal** disk's raw node, never
a suspect device.

```sh
PROBE='sysopen(my $f,$ARGV[0],POSIX::O_RDONLY()) or die sprintf("open errno=%d (%s)\n",$!+0,$!); my $n=sysread($f,my $b,4096); die sprintf("read errno=%d (%s)\n",$!+0,$!) unless defined $n; print "read ok: $n bytes\n"'

TO 15 perl -MPOSIX -e "$PROBE" /dev/rdisk0                        # (a) non-root
sudo -v                                                           # authenticate first: sudo cannot prompt from inside TO's process group
TO 15 sudo perl -MPOSIX -e "$PROBE" /dev/rdisk0                   # (b) root, terminal has NO grant
# grant FDA to the terminal app, quit it fully, relaunch it, then:
TO 15 sudo perl -MPOSIX -e "$PROBE" /dev/rdisk0                   # (c) root, FDA granted
TO 15 sudo dd if=/dev/rdisk0 of=/dev/null bs=4096 count=1          # (d) cross-check
```
**Read size is 4096, not 512.** Apple internal storage has a 4096-byte device block
and raw character nodes want block-aligned reads, so a 512 B read can fail with
`EINVAL` (errno 22) *after* access was granted. If you see `read errno=22`, access
worked; record it, and size probes from `DeviceBlockSize` in `diskutil info`.

If the terminal already has FDA, remove it, relaunch, and record (b) first — (b)
must be the *ungranted* baseline or row 7 is meaningless.

Also test one **non-internal** node if any exists (`/dev/rdisk0s1`) to see whether
per-node permissions differ.

Expect: (a) `open errno=13 (Permission denied)` — Unix permissions, not TCC;
(b) `open errno=1 (Operation not permitted)` — TCC denial; (c) `read ok: 4096 bytes`; (d) `1+0 records in`. If your account is in the `operator` group, (a) may
succeed; then record the Unix case from whatever node does deny you, and say
which — row 7 needs the two errnos side by side, not a memorised label.

Record per state: errno number + text, whether it was TCC or Unix, and the grant
path shown in System Settings. Errnums: 1 = EPERM, 13 = EACCES. Paste all four
results into `captures/a3-errno.md` (no `tee` — it hides the exit status).

- **Row 7** — yes only if (a) and (b) return *different* errnos. Then use the
  if-yes branch. If both are EPERM, apply the if-no branch (single "denied"
  state, both remedies).
- **Row 8** — yes if (c) succeeds, i.e. the internal node is a valid probe with
  no target disk in the loop. Then if-yes. Otherwise if-no: one bounded,
  time-limited read of the target.

### A4 — Process attribution: Terminal vs `.app` — row 6 (mechanism) and §7

```sh
mkdir -p captures/fdaprobe.app/Contents/MacOS
cat > captures/fdaprobe.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>probe</string>
  <key>CFBundleIdentifier</key><string>dev.disktriage.fdaprobe</string>
  <key>CFBundleName</key><string>fdaprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
cat > captures/fdaprobe.app/Contents/MacOS/probe <<'SH'
#!/bin/sh
# adjust the output path to this checkout; the app does not inherit the shell's cwd
exec /usr/bin/perl -MPOSIX -e 'sysopen(my $f,$ARGV[0],POSIX::O_RDONLY()) or die sprintf("open errno=%d (%s)\n",$!+0,$!); my $n=sysread($f,my $b,4096); die sprintf("read errno=%d (%s)\n",$!+0,$!) unless defined $n; print "read ok: $n bytes\n"' /dev/rdisk0 > "$HOME/Projects/<checkout>/captures/fda-probe-app.txt" 2>&1
SH
chmod +x captures/fdaprobe.app/Contents/MacOS/probe
codesign --force --sign - captures/fdaprobe.app    # ad-hoc: keyed by path+hash
open captures/fdaprobe.app
sleep 2; cat captures/fda-probe-app.txt
```
Replace `<checkout>` with this checkout's directory name — the app runs outside the
shell, so the output path must be absolute.
Then, with **Terminal's** FDA removed and only the `.app` added (System Settings →
Privacy & Security → Full Disk Access → `+`), repeat A3(b) (the `sudo` probe) from a
freshly launched Terminal; the non-root probe fails on Unix permissions either
way, so it cannot show attribution.

Expect: app run prints `read ok: 4096 bytes` while the Terminal run is denied —
that proves TCC follows the responsible process. Record which grant produced which
result, and that an ad-hoc signature loses the grant on every rebuild.

- **Row 6** needs the ddrescue half of this (B0). Note the result here; decide in B0.

### A5 — DiskArbitration dissent: prototype notes — row 5 (prep)

API verified against `DiskArbitration.framework` headers in this SDK:

- `DADiskMountApprovalCallback` is `DADissenterRef (^)(DADiskRef, void *)`.
  Return `NULL` to approve, a dissenter to **dissent**.
- Register with `DARegisterDiskMountApprovalCallback(session, match, callback, context)`
  on a session from `DASessionCreate`, driven by `DASessionScheduleWithRunLoop`
  or `DASessionSetDispatchQueue`.
- Dissent object: `DADissenterCreate(allocator, status, string)` — note there is
  **no disk parameter**; relevant statuses `kDAReturnExclusiveAccess`,
  `kDAReturnBusy`, `kDAReturnNotPermitted`.
- `DADiskGetBSDName(disk)` returns `const char *` for the log line.

Sketch to compile at the bench (`swiftc -O -framework DiskArbitration
captures/dadissent.swift -o captures/dadissent`, requires P1):

```swift
import DiskArbitration
import CoreFoundation
let cb: DADiskMountApprovalCallback = { disk, _ in
    let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
    fputs("dissent \(bsd)\n", stderr)
    return DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnExclusiveAccess), nil)
}
let session = DASessionCreate(kCFAllocatorDefault)!
DARegisterDiskMountApprovalCallback(session, nil, cb, nil)
DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
CFRunLoopRun()
```
Expect (if row 5 is yes): `dissent diskN` on plug-in and no `/Volumes/*` entry.
This is the runtime test in B3; compile it here so B3 is not blocked by tooling.
Mark the sketch as **unverified compile** — names come from the headers, the
build happens at the bench.

### A6 — Timeout apparatus self-test — row 10 (apparatus)

```sh
TO 5 sleep 30; echo "rc=$?"          # expect 124
TO 5 sh -c 'exit 3'; echo "rc=$?"    # expect 3
pgrep -fl 'sleep 30' || echo "no leftover child"   # expect none
```
Expect `124`, `3`, and no surviving child. If a child survives, the wrapper is
wrong and row 10 cannot be judged in Phase C — fix this first.

---

## Phase B — healthy control disk, both enclosures

Never the MiNaH drive. Two variants of every hardware step: E1 and E2. Capture
filenames carry `-e1` / `-e2`.

### B0 — ddrescue child inherits the terminal's TCC grant — row 6

No external disk; reads 1 MiB of the **internal** node into `captures/`.

```sh
TO 120 ddrescue -n -s 1048576 /dev/rdisk0 captures/q6-e1.img captures/q6-e1.mapfile
echo "rc=$?"
```
`UNVERIFIED (tool not installed)`: `-n/--no-scrape`, `-s/--max-size`.

Expect: `Finished`, `rescued: 1048576 B`, and a mapfile with `?`/`+` lines.
Then repeat with the terminal's FDA removed and the terminal relaunched.

- **Row 6** — yes only if the *child* succeeds while only the terminal holds the
  grant, and fails with EPERM when it does not. Then if-yes ("Option A survives").
  A child that needs its own grant, or that needs `sudo` plus a grant, is if-no.

### B1 — Tiny test volume, then ddrescue quirks — row 9

```sh
TO 60 diskutil image create blank --size 33554432 --fs MS-DOS \
      --volumeName DTQUIRK captures/q9-quirk.img
TO 60 diskutil image attach --readOnly --noMount --plist captures/q9-quirk.img
TO 20 diskutil list | grep -B2 -A2 DTQUIRK     # note the new diskN
```
Expect: a 32 MiB image, an attached `/dev/rdiskN` with `MountPoint` empty.
Now the quirks (`UNVERIFIED (tool not installed)` throughout; `-n`, `-b`,
`-O`, `-K`, `-T`, `--max-read-rate` are ddrescue's documented options):

```sh
TO 120 ddrescue -n          /dev/rdiskN captures/q9-buffered.img captures/q9-buffered.mapfile
TO 120 ddrescue -n -d       /dev/rdiskN captures/q9-direct.img   captures/q9-direct.mapfile
TO 120 ddrescue -n          /dev/diskN  captures/q9-blockdev.img  captures/q9-blockdev.mapfile
TO 120 ddrescue -n -b 4096  /dev/rdiskN captures/q9-bs4096.img   captures/q9-bs4096.mapfile
TO 120 ddrescue -n -O -T 10s --max-read-rate=4MiB /dev/rdiskN captures/q9-reopen.img captures/q9-reopen.mapfile
TO 120 ddrescue -n --skip-size=64KiB,4MiB -T 10s    /dev/rdiskN captures/q9-skip.img   captures/q9-skip.mapfile
```
Append `> captures/q9-<name>.log 2>&1; echo "rc=$?"` to each line: the error text
is the answer, and `tee` would hide the exit status.

Record per invocation: exit code, whether it completed, the exact error text,
the sector size it reported, and whether the mapfile shows a full rescue. Each
run is a fresh destination file; never reuse one without its mapfile.

- **Row 9** — yes if every flag behaves as documented (direct I/O accepted or
  cleanly refused, `/dev/rdiskN` preferred, `-O`/`-K`/`-T` accepted). Any flag the
  wrapper cannot rely on → if-no: adjust defaults, document the workaround.

Detach when done: `TO 30 diskutil eject /dev/diskN`.

### B2 — Control disk on E1 — rows 1, 2, 3

Attach with the bridge powered and the disk unmounted by the OS as usual (this is
the healthy control; an automount here is untidy but harmless — record it).

Identity first (the plan forbids trusting `diskN` alone):

```sh
TO 20 ioreg -p IOUSB -l -w 0 -d 0 -c IOUSBHostDevice    # bridge name, VID/PID, serial
TO 20 diskutil list -plist                                # new diskN + size
TO 20 diskutil info -plist /dev/diskN | grep -A1 -E 'MediaName|DeviceBlockSize|Size|BusProtocol|MountPoint|DeviceNode'
TO 20 ioreg -r -c IOMedia -d 1 -w 0 | grep '"BSD Name"'
TO 20 mount | grep -c "/dev/diskN"                        # expect 0 for a bare-disk bench
```
Record: model, serial (bridge or drive), size, block size, bus, and the bridge
VID/PID — this is the start of the per-bridge known-good list.

**Row 1 — SMART over this bridge** (`UNVERIFIED (tool not installed)`):

```sh
TO 30 smartctl --scan > captures/q1-e1-scan.txt 2>&1; echo "rc=$?"
TO 30 smartctl -a -d sat /dev/diskN > captures/q1-e1-nonroot.txt 2>&1; echo "rc=$?"
TO 30 sudo smartctl -a -d sat /dev/diskN > captures/q1-e1-root.txt 2>&1; echo "rc=$?"
```
Expect text: `Device Model`, `Serial Number`, `SMART overall-health
self-assessment test result`, the attribute table, `ATA Error Count`. Record the
exit status and the exact failure text for each of the two runs. Then repeat on
E2 as `q1-e2-*`.

- **Row 1** — yes if `-d sat` returns attributes over USB **and** neither run
  needed TCC/root. If it works only as root, or only with FDA, the "no" branch's
  TCC/root half applies. If it works on E1 but not E2, the bridge half applies
  ("publish a per-bridge known-good list"). Decide per bridge and say so.

**Row 2 — I/O counters** (verified syntax on the internal SSD; the USB answer is
the question):

```sh
TO 20 ioreg -r -c IOBlockStorageDriver -k Statistics -d 1 -w 0 > captures/q2-before-e1.txt
TO 60 dd if=/dev/rdiskN of=/dev/null bs=1048576 count=8; echo "rc=$?"
TO 20 ioreg -r -c IOBlockStorageDriver -k Statistics -d 1 -w 0 > captures/q2-after-e1.txt
diff captures/q2-before-e1.txt captures/q2-after-e1.txt
```
Expect a `Statistics` dict per device with `Operations (Read)`, `Bytes (Read)`,
`Retries (Read)`, `Errors (Read)`, `Total Time (Read)`. Record which keys exist on
the **USB** node and which of them moved by exactly the 8 MiB read.

- **Row 2** — yes only if per-device `Retries`/`Errors` exist on the USB node and
  at least one counter was observed to move with real I/O. A key that exists but
  never moves is display-only: a healthy drive cannot distinguish "no retries"
  from "counter not wired". If either half fails, if-no applies (display only,
  recalibrate confidence). Note in the record that under this rule zero is never
  read as health.

**Row 3 — unified log** (macOS `log` is also a zsh builtin: always `/usr/bin/log`):

```sh
TO 120 /usr/bin/log stats > captures/q3-log-stats.txt      # TTL buckets: 1/3/7/14/30 d
TO 120 /usr/bin/log show --last 30d --style ndjson \
   --predicate 'eventMessage CONTAINS[c] "medium error" OR eventMessage CONTAINS[c] "I/O error"' \
   > captures/q3-medium-errors.ndjson
TO 120 /usr/bin/log show --last 7d --style ndjson \
   --predicate 'subsystem == "com.apple.iokit.IOStorageFamily"' \
   > captures/q3-iokit.ndjson
```
Expect: `log stats` prints a `ttl` table with counts per bucket; the queries print
zero or more ndjson lines, each with timestamp, process, subsystem and
`eventMessage`. Record the retention buckets and whether any **medium-error line
carrying an LBA** exists.

- **Row 3** — yes only if a real medium-error entry with an LBA is present in the
  retained window; then record that window's hours in `log.window_hours` and use
  if-yes. Nothing on a healthy bench can create one, so if there is none, record
  "not observable on hardware that is healthy" and re-query immediately after
  Phase C (C3) — that is the one chance to see the real event and its retention.
  If it still cannot be observed, record the row as **unproven** and apply the
  if-no branch **provisionally**, flagging that the plan's row-3 if-no is a scope
  decision.

Repeat B2 on E2 as `-e2`.

### B3 — Does a dissent block the third-party driver? — row 5

Needs a small **NTFS** test volume on the scratch disk, created deliberately with
the third-party personality listed by `diskutil listFilesystems` (e.g. `Windows
NTFS`); or the already-captured MiNaH image attached read-only. Never write to
the control disk's data.

```sh
# writes: scratch volume ONLY. Verify the target first: diskutil info /dev/diskN
TO 120 diskutil eraseVolume iboysoft_NTFS DTNTFS /dev/diskN   # personality name from P6
TO 20  diskutil info -plist /dev/diskN | grep -A1 -E 'FilesystemType|MountPoint'
```

```sh
TO 120 ./tools/p0/build-dadissent.sh                     # -> captures/dadissent (ad-hoc signed)
sudo -v                                                  # authenticate: the probe runs as root (see A5)
TO 600 sudo -n captures/dadissent --seconds 600 > captures/q5-dissent.log 2>&1 &
# with it running, plug the control disk / attach the NTFS volume via E1
TO 600  diskutil activity > captures/q5-da-activity.log 2>&1 &   # continuous; kill after
TO 20  mount | grep -i ntfs > captures/q5-mount.txt; echo "rc=$?"
TO 20  ioreg -r -c IOMedia -d 1 -w 0 | grep '"BSD Name"'
```
Expect if row 5 is yes: `decision … verdict=dissent` lines, no `/Volumes/*` mount, and the
driver's own mount attempt failing (`kDAReturnExclusiveAccess`) in the DA activity
log. Expect if no: the volume appears mounted anyway — record which driver did it.
Root: the SDK headers set no privilege rule and `DARegisterDiskMountApprovalCallback`
returns void, so an unprivileged run is indistinguishable from an ignored one; B3
runs the probe as root so that variable is closed.

- **Row 5** — yes only if the dissent blocks the **third-party** driver's mount,
  not just the native one. Otherwise if-no: principle 1 becomes advisory; choose
  disable-driver instructions or downgrade the principle honestly.

Stop the listeners explicitly — killing the `TO` wrapper does not kill its child:
`sudo pkill -f 'captures/dadissent'; pkill -f 'diskutil activity'` — then eject.

### B4 — `F_LOG2PHYS_EXT` on the native read-only NTFS mount — row 4

No hardware risk: use the existing image if present, else the B3 test volume.

```sh
TO 60 diskutil image attach --readOnly --noMount --plist /path/to/minah.img > captures/q4-attach.txt 2>&1; echo "rc=$?"
# then, only if a native mount helper exists (A2):
TO 60 mount -t ntfs -o ro /dev/diskN /Volumes/dtro > captures/q4-mount.txt 2>&1; echo "rc=$? a hang is a finding"
```
If no native helper exists, stop here: there is nothing to test and no ioctl can
make the mount appear.

If it mounts, query one **existing** file (never create one on the image):
`F_LOG2PHYS_EXT` = 65 in `sys/fcntl.h`; `struct log2phys { unsigned int
l2p_flags; off_t l2p_contigbytes; off_t l2p_devoffset; }`, with `l2p_contigbytes`
in = bytes to query, out = contiguous bytes, and `l2p_devoffset` out = device
offset. Call `fcntl(fd, F_LOG2PHYS_EXT, &l2p)` on an `O_RDONLY` fd.

```sh
cat > captures/l2p.c <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
int main(int c, char **v){ int fd=open(v[1],O_RDONLY); struct log2phys l={0};
  if(fd<0){perror("open");return 2;}
  l.l2p_contigbytes=4096;
  if(fcntl(fd,F_LOG2PHYS_EXT,&l)){perror("F_LOG2PHYS_EXT");return 1;}
  printf("devoffset=%lld contig=%lld\n",(long long)l.l2p_devoffset,(long long)l.l2p_contigbytes); return 0; }
C
clang -o captures/l2p captures/l2p.c && TO 20 ./captures/l2p "/Volumes/dtro/<existing file>" > captures/q4-l2p.txt 2>&1; echo "rc=$?"
```
Expect either `devoffset=<n> contig=<n>` (ioctl supported) or
`F_LOG2PHYS_EXT: ...` (ENOTTY/EINVAL/EPERM).

- **Row 4** — yes only if the ioctl returns a plausible device offset on the
  **native read-only NTFS** mount. Absent native NTFS mount, or a failed ioctl →
  if-no (volume-level reporting in v1, runlist parser in v1.1).

Unmount/detach the image when finished.

### B5 — Collector timeout drill on healthy hardware — row 10 (apparatus)

A collector that never terminates by design, so the kill path is exercised with
nothing at risk:

```sh
TO 5 diskutil activity > captures/b5-timeout.log 2>&1; echo "rc=$?"   # expect 124
pgrep -fl diskutil || echo "no leftover"                              # expect none
TO 5 smartctl --scan > captures/b5-scan.txt 2>&1; echo "rc=$?"        # UNVERIFIED (not installed)
```
Record: `124`, no surviving `diskutil`, and that `captures/b5-timeout.log` holds
the partial output (partial evidence is still evidence). This proves the harness;
the real failing-disk behaviour is Phase C.

- **Row 10** — B5 + C3 together decide it. B5 alone only proves the wrapper.

---

## Phase C — MiNaH, last, minimum reads, hard budget

**Hard budget: 20 minutes from first power-on.** 5 min guard + connect, 2 min
identity, 1 min one SMART query, 5 min one bounded read, rest teardown. Nothing
is retried. This phase exists to answer row 10 (and to confirm row 1 on a truly
failing drive if the budget allows).

### C0 — Pre-flight (before the drive is anywhere near the Mac)

- `TO 30 diskutil list -plist > captures/c0-disks-before.plist` and
  `ls /dev/rdisk* > captures/c0-nodes-before.txt`.
- `caffeinate -dimsu -w $$ &` (or prefix each command with `caffeinate -dimsu`).
- Power strip switch reachable; enclosure on the desk, drive not yet powered.
- Note room temperature and that the drive has been idle/cool for ≥ 30 min.
- Choose the enclosure that **passed row 1** (SMART visible). Record which.

### C1 — Stop macOS mounting it before it exists (mount guard)

Preferred: run the A5/B3 dissent probe (row 5 yes) and watch its log:

```sh
TO 1200 ./captures/dadissent > captures/c1-dissent.log 2>&1 &
```
Fallback, if the dissent did not work: suspend DiskArbitration for the duration.
While it is suspended **`diskutil` hangs** — enumerate with `ioreg`/`ls` only.

```sh
DA=$(pgrep -x diskarbitrationd); ps -o stat= -p "$DA"      # expect Ss
sudo kill -STOP "$DA"; ps -o stat= -p "$DA"                # expect T (stopped)
```
If `kill -STOP` is refused, **do not connect the drive**: that is a STOP condition
(principle 1 has no enforcement), record it and end Phase C.

### C2 — Connect it so the OS never gets a mountable moment

1. USB cable into the Mac first, **enclosure unpowered** (drive not spinning).
2. Confirm nothing appeared:
   `ls /dev/rdisk* | diff captures/c0-nodes-before.txt -` (expect no output) and
   `ioreg -r -c IOMedia -d 1 -w 0 | grep '"BSD Name"'` — same set as C0.
3. Power the enclosure (drive spins up). Wait ≤ 10 s.
4. Confirm a new node appeared and nothing is mounted:
   `ls /dev/rdisk*`; `mount | grep -c rdisk` (only your own system disks);
   `diskutil list` **only if** DA is running (dissent path).
5. If a volume mounts anyway: `TO 30 sudo diskutil unmountDisk force /dev/diskN`;
   if that hangs, power off — that is a STOP condition, not a retry.

### C3 — The minimum evidence, in this order

```sh
# identity (no media read): model/serial/size
TO 20 ioreg -r -c IOMedia -d 1 -w 0 | grep -E '"BSD Name"|"Size"'
TO 20 ioreg -p IOUSB -l -w 0 -d 0 -c IOUSBHostDevice > captures/c3-usb.txt
grep -iE 'USB Product Name|USB Serial Number|idVendor|idProduct' captures/c3-usb.txt

# one SMART query (row 1 confirmation on the failing drive)
TO 60 sudo smartctl -a -d sat /dev/diskN > captures/c3-smart.txt 2>&1; echo "rc=$?"
# the other collector named in row 10 (only if DA is running); also identity
TO 30 diskutil info -plist /dev/diskN > captures/c3-diskutil.txt 2>&1; echo "rc=$?"

# ONE bounded read: first 4 MiB, nothing else
TO 120 dd if=/dev/rdiskN of=captures/c3-first4m.bin bs=1048576 count=4; echo "rc=$?"
```
(`UNVERIFIED (tool not installed)`: the `smartctl` line.) Expect: `MediaName`
containing `WD3200BJKT`, `Size` 320 GB, SMART with `197 Current_Pending_Sector`
≈ 131 and `ATA Error Count` > 0; `dd` either `4+0 records in` quickly, or a stall
until `TO` returns 124, or an `Input/output error`.

Immediately after the read, capture the evidence the read may have created:

```sh
TO 120 /usr/bin/log show --last 10m --style ndjson \
   --predicate 'eventMessage CONTAINS[c] "medium error" OR eventMessage CONTAINS[c] "I/O error"' \
   > captures/c3-medium-errors.ndjson
TO 20 ioreg -r -c IOBlockStorageDriver -k Statistics -d 1 -w 0 > captures/c3-stats-after.txt
TO 10 ls /dev/rdisk* > captures/c3-nodes-after.txt
ps -Ao pid,stat,command | grep -E 'dd|smartctl' | grep -v grep
```
Record: duration of the read, `Retries`/`Errors` delta, whether the device
disappeared from `ls /dev/rdisk*`, whether a hung process survived `TO`, and the
process state (`stat`) of anything left.

Then re-answer row 3 from `c3-medium-errors.ndjson` (this is the only chance to
see a real medium-error event with an LBA) — and note that retention can only be
measured by re-querying later, so record the timestamp of the event.

- **Row 1 (confirm)** — if SMART still returns over this bridge: supports the
  A3/B2 answer on a failing drive. If it now times out, that is row 10 evidence,
  not a row 1 flip.
- **Row 3** — from the same ndjson.
- **Row 10** — yes if a collector stalled and `TO` returned 124 with a
  **process-group kill that left nothing behind** (no surviving `dd`, no wedge).
  If a process survives SIGKILL, or the CLI can only be unblocked by the device
  disappearing, if-no applies: accept `timeout` as the verdict and never wait.
  If nothing stalled inside the budget, row 10 is **not answered** — record
  "unproven" and keep the wrapper; do not invent a pass.

### C4 — STOP conditions (immediate, no retry)

Power off with the strip switch, then record and stop. Do not re-plug, do not
raise the timeout, do not "try once more".

| Trigger | Action |
|---|---|
| Any click, tick, or grind | power off; that is a HEAD-class symptom (plan §5 step 7), not a timeout finding; recommend professional recovery |
| Device disappears from `ls /dev/rdisk*` | power off; record time and last command |
| Any read stalls past its timeout (124) | power off; treat as `timeout` evidence |
| Enclosure/drive case too hot to hold | power off |
| SCSI resets or repeated re-enumeration | power off |
| FDA/DA state lost (volume mounts, probe dies) | power off; the read is no longer guarded |

### C5 — Teardown

1. Power off the enclosure; disconnect USB.
2. If DA was stopped: `sudo kill -CONT "$DA"; ps -o stat= -p "$DA"` (expect `Ss`).
3. Stop the dissent probe and `caffeinate` (`pkill -f 'captures/dadissent'`);
   `mount | grep -c rdisk` back to baseline.
4. Write `captures/c5-session.md`: start/end time, total drive-powered minutes,
   every command with its exit code, and any STOP event.

---

## What not to do

- No `fsck*`, no Disk Utility First Aid, no `diskutil
  verifyVolume/repairVolume/verifyDisk/repairDisk` — on any device. Filesystem
  work happens on a copy of the image.
- Never mount the MiNaH drive; never "just check" whether it mounts.
- No `smartctl -t` self-tests, no `-X`, no SMART polling during any long read.
- No writes to any device that holds data: no `diskutil erase*` outside the B3
  scratch test volume, no `zeroDisk`, `randomDisk`, `partitionDisk`, no
  `dd of=/dev/*`, no `mount -w`.
- Do not let the Mac sleep during a read: `caffeinate` for the whole session.
- Do not retry after a STOP condition, and do not raise a timeout to "see".
- Do not run `diskutil` while DiskArbitration is stopped (it hangs) and do not
  trust `log` (zsh builtin) — call `/usr/bin/log`.
- Do not read a command's exit status through a pipe; take `$?` from `TO`.
- No `git add -A`; `captures/` never gets committed, only redacted fixtures do.

---

## Results

### Bench facts (fill in before any decision)

| Item | Value |
|---|---|
| Date / operator | 2026-11-06 / fd (Phase A only) |
| Host model, arch, `sw_vers` build | MacBook Air M1 (MacBookAir10,1), arm64, macOS 27.2 build 26B123 |
| Xcode version | 27.2 (27B52), Swift 6.4.2 |
| Terminal app + version | Ghostty 1.4.0 |
| Control disk model / serial / size | Seagate Expansion (USB bridge VID:PID 0bc2:231a), 5.0 TB, 512 B blocks, GPT, NTFS data partition; model and serial not readable (no SMART) |
| Scratch volume, free space | |
| E1 bridge name / VID:PID | Seagate Expansion built-in bridge, 0bc2:231a (only bridge available; E2 not tested) |
| E2 bridge name / VID:PID | VLI (VIA Labs) USB-SATA bridge, 2109:0715, with a Samsung SSD 850 EVO 250 GB (`SolidState` absent in diskutil, `SMARTStatus: Not Supported`) |
| Third-party NTFS driver(s) (`listFilesystems`, `/Library/Filesystems`, `/Library/Extensions`) | `iboysoft_NTFS` personality; `/Library/Filesystems/iboysoft_NTFS.fs`; `/Library/Extensions/ms_ntfs.kext` (also CIJUSBLoad.kext, SoftRAID.kext) |
| Native `mount_ntfs` present? (A2) | **No.** `man -w mount_ntfs` rc=1; `ntfs.fs/Contents/Resources` has `ntfs.util` and `BootCampFormatter`, no mount helper. Row 4 is answered by absence. |
| `smartctl --version` / `ddrescue --version` | smartctl 7.5 2025-04-30 r5714 / GNU ddrescue 1.30 |

### Decision table — one row per P0 question

| # | Question | Answer (yes / no / unproven) | Evidence file (`captures/…`) | Decision taken (quote the branch applied) |
|---|---|---|---|---|
| 1 | `smartctl -d sat` over USB; TCC/root needed? | **no, and not because of TCC or root.** As root with Ghostty granted, every device type fails: `-d sat` and `-d scsi` give "Not a device of type 'scsi'", `-d auto` and `-d ata` give "Operation not supported by device" (smartctl exit 1 or 2). `diskutil` also reports `SMARTStatus: Not Supported`. | `phase-b/q1-*` | Branch applied (if-no, bridge or OS cause): `BRIDGE` / no-SMART is the common path; confidence loses the SMART source on such disks; FDA is NOT on the critical path for triage. **Second bridge tested (VLI 2109:0715 + Samsung SSD 850 EVO): all 11 device types fail the same way, so this is macOS-wide for USB mass storage on this build, not bridge-specific.** |
| 2 | `ioreg` exposes real retries/timeouts for USB disks? | **yes, counters are real, but there is no timeouts counter.** The Seagate's `IOBlockStorageDriver` Statistics tracked a 64 MiB read exactly: Bytes (Read) +67,108,864 and Operations (Read) +64. Available for Read and Write: Bytes, Operations, Total Time, Latency Time, **Retries**, **Errors**. Retries and Errors stayed 0 on a healthy disk; **Phase C (MiNaH): `Errors (Read)` went 0 -> 1 after the failed read, but `Retries` stayed 0 although the kernel retried 20 times, so Errors is a usable after-the-fact signal and Retries is not.** | `phase-b/q2-before.txt`, `q2-after.txt`, `q2-dd.txt` | Branch (if-yes) applied provisionally: Retries and Errors are a candidate independent source, but keep `p0_validated` off until MiNaH shows them moving. Drop "timeouts" from the I/O model or source it from the kernel log. |
| 3 | Unified log retains medium errors with LBAs, and for how long? | **yes (phase C):** the kernel log carries the medium error with the LBA (see Phase C findings), readable by `log show` without root. Retention length is still unmeasured. Side evidence: `log show` works without root; `log stats --overview` hung past the 60 s timeout (exit 124, empty output; the wrapper killed it and no process was left), so do not use it to measure retention. | `phase-b/q3-log-show.txt`, `q3-log-stats.txt` | Branch (if-no, provisional): re-query after the MiNaH capture; do not claim the no-SMART path has a log signal until then. |
| 4 | `F_LOG2PHYS_EXT` works on the native read-only NTFS mount? | **no, by absence** (A2) | `a2.txt` | Branch applied: volume-level reporting in v1; NTFS runlist parser for v1.1. Also raises the plan question: no native NTFS reader exists on this macOS build (see below). |
| 5 | DiskArbitration dissent blocks third-party driver mounts? | **yes for the mount, no for the probe.** On replug of the Seagate the probe logged `decision bsd=disk8s2 protocol=USB fs=iboysoft_NTFS verdict=dissent`; 0 mounted entries for the device afterwards. But the third-party driver's `ms_ntfs.util -p disk8s2` and `-k disk8s2` still ran **before** the approval and read the volume (sector_per_cluster, volume label, volume UUID key). | `phase-b/q5-summary.txt`, `q5-dissent.log`, `q5-log.txt` | Branch (if-yes) applied: `guard` is the mount enforcement mechanism. Principle 1 must be narrowed: a dissent stops the **mount** (journal replay, dirty flag, writes) but not the driver's **probe reads**, which touch the boot sector and early metadata. Caveat: no un-guarded control run in this step; an earlier unmount of the same disk shows it automounts by default. |
| 6 | ddrescue child inherits the TCC grant under option A? | **yes** for the sudo-launched path: `sudo ddrescue` run from Ghostty with Full Disk Access read `/dev/rdisk8` (16 MiB, 0 errors). Mechanism half answered in A4: a compiled, ad-hoc-signed `.app` holds its own grant (EPERM 1 -> EACCES 13 once granted) while Ghostty, ungranted, stays EPERM; a shell-script app executable holds no grant. | `phase-b/q6.*`, `fda-probe-app.txt`, `a3-errno.md` | Option A (Terminal) survives for sudo-launched children. Untested: a child of the signed `.app` helper (options B and C). |
| 7 | TCC errno (`EPERM`) differs from Unix (`EACCES`)? | **no, as the runbook defined it**: ungranted, non-root and root both return EPERM (1). **But** once TCC passes, a non-root open returns EACCES (13) (app test). TCC is evaluated before Unix permissions. | `a3-errno.md`, `fda-probe-app.txt` | Branch applied (if-no): single `denied` state, both remedies. Refinement: EPERM => grant FDA first; EACCES => FDA is fine, run as root. |
| 8 | Raw read of the internal disk works as an FDA probe? | **yes** (root + Ghostty granted: `read ok: 4096 bytes`; `dd bs=4096` ok) | `a3-errno.md` | Branch applied (if-yes): probe the internal node, off the suspect disk. Use a 4096-byte aligned read. |
| 9 | ddrescue on macOS: direct I/O, sector size, `/dev/rdiskN`, `-O`, `-K`? | **partly no:** `-d` (direct) fails ("Direct disc access not available", exit 1), so it must not be used. Plain, `-b 4096`, `-n -O -K 65536`, and the buffered `/dev/disk8` node all exit 0, and all four 16 MiB images are byte-identical to a `dd` reference (same SHA-256). | `phase-b/q9-*`, `ddrescue-help.txt` | Wrapper defaults: use `/dev/rdiskN`, no `-d`, `-b` = device block size; `-O` and `-K` are accepted. Reopen-on-bus-drop itself is UNVERIFIED (needs a real drop). |
| 10 | `diskutil`/`smartctl` hang on a failing disk; timeout + kill work? | **partly (phase C):** one raw read of the failing drive blocked 48 s (20 kernel retries about 2.2 s apart) and then returned an I/O error. It was not an indefinite hang, so the 120 s wrapper was not triggered; no leftover process, no uninterruptible state. A true hang is still unreproduced. The apparatus works: the `TO` wrapper killed a real slow command (`log stats`, exit 124, no survivor). | `phase-b/q3-log-stats.txt` | Pending Phase C. |

Closing decision (plan §9): process identity for FDA = A / B / C, plus the chosen
implementation language. Write it here, with the row that forced it:

```
Process identity: ______   (forced by rows ____)
Language: ______
Open questions carried into P1: ______
```


### Phase A findings (2026-11-06)

- **Row 7 / 8:** EPERM (1) = TCC denied, regardless of root. EACCES (13) = TCC passed, Unix
  permissions denied. So a non-root probe can tell "FDA granted" (EACCES) from "FDA missing"
  (EPERM) without sudo. **Confirmed** with Ghostty granted + non-root: errno 13.
- **A4 attribution:** the grant follows the responsible `.app`, not the terminal. Ad-hoc signed
  rebuilds with **identical bits keep the grant** (same cdhash). The plan's "ad-hoc builds lose
  the grant on every rebuild" is true only when the bits change. **Confirmed:** a rebuild with a new build id (new cdhash)
  returned errno 1 again, so the grant was lost.
- **Script executables carry no TCC identity** (the process is `/bin/sh`): any helper must be
  a Mach-O.
- **No native NTFS reader** on macOS 27.2 build 26B123. Plan §2 principle 4 and §8 inspection
  (`mount_ntfs`) need a decision: third-party reader on the image only, own parser, or NTFS
  inspection unsupported here.
- **Raw reads need block alignment**: probes use 4096 bytes.


### Phase B findings (2026-11-07, control disk: Seagate Expansion 5 TB)

- **SMART is not reachable through smartctl on macOS 27.2 with this Seagate bridge**, even as root
  with Full Disk Access. The cause is the OS or bridge path, not permissions. A third-party SAT SMART
  driver is the known workaround and would conflict with the no-driver principle; not pursued.
  Triage must therefore work without SMART (kernel log, ioreg I/O statistics, symptoms) and say so.
- **ioreg Statistics are real and consistent** (a 64 MiB read moved Bytes (Read) by exactly 64 MiB
  and Operations (Read) by 64), including Retries and Errors counters. There is no timeouts counter.
- **At plug-in macOS runs the third-party driver's probe before any tool can act**:
  `ms_ntfs.util -p disk8s2 removable readonly` and `SystemUIServer ... premount disk8s2` appear in
  the log. Direct evidence that `guard` must already be running before connection (principle 1).
- **ddrescue on macOS:** no `-d`; use the raw node; images match `dd` byte for byte.
- **Mount guard (row 5):** the dissent blocks the mount of a third-party NTFS volume, but the
  driver's probe (`ms_ntfs.util -p` / `-k`) runs first and reads the volume, including the volume
  label from metadata. On a failing disk that probe can itself stall or hang; if the original MiNaH
  hang occurred at probe time, `guard` alone would not have prevented it. Plan principle 1 and the
  `guard` description should say "never mount", not "never touch"; the only way to avoid probe
  reads is not to have the disk visible to macOS (Linux rescue image, or a different host).

### Second bridge (2026-11-07): VLI 2109:0715 + Samsung SSD 850 EVO 250 GB

- `smartctl -i` as root with Full Disk Access, 11 device types (`sat`, `auto`, `scsi`, `ata`,
  `sntasmedia`, `sntjmicron`, `sntrealtek`, `usbjmicron`, `usbsunplus`, `usbcypress`, `nvme`):
  every one failed ("Not a device of type 'scsi'" or "Operation not supported by device").
  Two unrelated bridges and two different drives behave identically, so smartctl cannot reach USB
  mass-storage SMART on macOS 27.2 here. Row 1 stays "no", now with the cause attributed to the OS.
- `diskutil` reports no `SolidState` key for either USB disk (the HDD and the SSD), so media type over
  USB is `unknown`; the collector already maps an absent `SolidState` to `unknown`. Triage must not
  assume HDD or SSD from diskutil alone over USB.


### Phase C findings (2026-11-07, MiNaH WD3200BJKT)

- **Identity and SMART:** ioreg size matched 320,072,933,376 bytes. `smartctl -d sat -a` failed the same
  way as on the other two bridges ("Not a device of type 'scsi'"): SMART is unreachable here too.
- **One raw read of the failing drive:** `dd bs=1M count=4` returned the first MiB (LBA 0-2047), then
  failed on the second MiB with `Input/output error` after **48 s**. LBA 2048 (0x800) is the NTFS boot
  sector, exactly as the plan states.
- **Kernel log format (real, replaces the plan's example wording):**
  `[External] I/O error! Opcode 0x28, Service response 0x02, Task status 0x02, Sense Data 0x03, 0x11, 0x00`
  (READ(10), CHECK CONDITION, sense key 3 MEDIUM ERROR, ASC 0x11 unrecovered read error), then
  `[External]: I/O error [0xe00002ca] dir 0x1 lba 0x800 count 0x100, retry 1 ...` up to retry 20 about
  2.2 s apart, then `disk8: I/O error.`. Repeats are coalesced as `... happened 42 times`. The LBA is
  in **hex**; the count varies with the reader (0x20 for a probe, 0x100 for the dd read).
- **An unguarded attach also happened ~3 minutes before the script began** (inferred from the log:
  `ms_ntfs.util -p`, `storagekitd` Appear at 00:31, kernel retries at lba 0x800 count 0x20 from
  00:31:21 to 00:32:55, `disk8s1: I/O error`). It shows the original failure mode: the third-party
  driver's probe and storagekitd hit the unreadable boot sector and the kernel retried for minutes.
  The probe calls ended and nothing hung indefinitely this time.
- **ioreg:** the MiNaH driver's `Bytes (Read)` rose by exactly 1,048,576 (the one good MiB) and
  `Errors (Read)` rose 0 -> 1; `Retries` did not move.
- **The mount guard worked:** with `diskarbitrationd` suspended during the script, the disk was never
  probed or mounted by the script's own session; it resumed cleanly (state `Ss`) after unplug.
- **Not done:** P0 row 11 (boot-sector restore on a working copy) needs the earlier MiNaH image,
  which is not on this Mac.
