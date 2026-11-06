# NTFS inspection spike — ntfsprogs without FUSE, on macOS 27.2

Status: spike result, 2026-11-06. Everything below was run on this host unless
marked **UNVERIFIED**. Scratch artifacts (images, prefixes, logs, the fixture
helper) live in `captures/ntfs-spike/`, which is gitignored; nothing here is
shipped code.

Host: macOS 27.2 (build 26B123), arm64 (M1), Xcode 27.2 (27B52), Apple clang
21.0.0 (clang-2100.4.1.1). No `sudo` was used. No mount was performed. No
kernel or system extension was installed. `macFUSE` happens to be present on
this host from an earlier install and a third-party NTFS kext
(`com.iboysoft.filesystems.ms_ntfs`) is loaded; neither was used, and the tools
built here link no FUSE library (verified with `otool -L`).

## Verdict

**Inspect: usable.** `ntfsinfo`, `ntfsls` and `ntfscluster` open a plain image
file, an extracted partition, or a `/dev/diskNsM` node from
`diskutil image attach --noMount --readOnly` and read it without mounting,
without a kernel extension, without Full Disk Access and without root. Every
command finished in 35–75 ms on a 64 MiB image.

**Copy-out: usable, but not self-verifying.** `ntfscat image /path > out`
reproduced an 8 MiB fragmented file byte-for-byte (SHA-256 match). The caveat is
the one §8 already states: a ddrescue hole is zeros, so `ntfscat` returns exit 0
and the right *length* for a file whose data was never read. Copy-out is only
meaningful when the caller has already intersected the mapfile; the tool will
not tell you.

**Per-file damage attribution: usable with caveats.** `ntfscluster -c
<first>-<last>` maps a cluster range back to inode + full path (`Inode 77
/media/clip.dat/$DATA`) and still does so when that file's data clusters have
been zeroed. It also names metadata (`Inode 0 /$MFT/$DATA`, `Inode 66
/media/$INDEX_ALLOCATION($I30)`) and answers `* no inode found` for free space.
The caveats: (1) it cannot open the volume at all once damage reaches `$MFT`
itself, so the worst case has no attribution; (2) it takes exactly one range per
invocation, and byte ranges are not accepted, so an N-extent mapfile becomes N
subprocesses; (3) no tool accepts a partition offset, so a whole-disk image must
be attached or extracted first.

## How to build

Homebrew is not a route on macOS. The core formula `ntfs-3g` (stable
2026.9.28) is Linux-only — it declares `depends_on :linux` and ships no macOS
bottle; `brew install ntfs-3g` answers `Error: ntfs-3g: no bottle available!`
and exits 1. The tap formula `gromgit/homebrew-fuse/ntfs-3g-mac` exists but does
`require_relative "../require/macfuse"`, i.e. it forces macFUSE and is out of
scope.

Source build, ntfsprogs only. Released tarball, checksum verified against the
SHA-256 published in the GitHub release notes (`350d9415…f295c8`):

```sh
mkdir -p captures/ntfs-spike/download && cd captures/ntfs-spike/download
curl -fSLO https://download.tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz
shasum -a 256 ntfs-3g_ntfsprogs-2026.9.28.tgz
# 350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8
tar -xzf ntfs-3g_ntfsprogs-2026.9.28.tgz -C ../stage && cd ../stage/ntfs-3g-2026.9.28

PREFIX=$PWD/../../prefix
./configure --prefix="$PREFIX" --exec-prefix="$PREFIX" \
    --disable-ntfs-3g --disable-shared --enable-static \
    --disable-ldconfig --disable-mtab --disable-mount-helper
make -j4 && make install
```

- `--disable-ntfs-3g` is the exact flag (`./configure --help`, "disable the
  ntfs-3g FUSE driver"). With it, configure never looks for libfuse, the mount
  helper is not installed, and `prefix/lib` contains only `libntfs-3g`.
- `--exec-prefix` is **required** when `--prefix` is not the default: without
  it `rootlibdir` stays `/lib`, and `make install` fails at the last step
  trying to `mv …/libntfs-3g.so* //lib` (harmless, but it exits 2).
- `--disable-shared --enable-static` gives self-contained binaries: `ntfsls`
  is 350 KB and links only `libSystem` and `CoreFoundation`. Without it the
  installed `libntfs-3g.91.dylib` is referenced by absolute install_name, so
  the prefix is not relocatable.
- No patch was needed. Warnings only (packed-member addresses, unused
  variables). First build `make -j4` = 9.83 s, install = instant; the static
  variant = 6.70 s. Installed prefix 6.2 MB.
- The tarball ships a generated `configure`; `autoconf`/`automake` are not
  required. Nothing beyond the Xcode toolchain was used.

Build with `--enable-extras` only if you want `ntfstruncate`/`ntfswipe`; the
seven tools named in the brief are all in the default `bin`/`sbin` set.

## Whole-disk image handling

Fixture: `disk.img` is an 80 MiB file with an MBR, one type-0x07 partition of
64 MiB at LBA 2048; the partition holds the same NTFS volume (4 KiB clusters)
as `plain.img`. Also verified: a bare partition image (`plain.img`) attaches as
a single whole `/dev/disk6`.

| Route | Result |
|---|---|
| (a) `diskutil image attach --noMount --readOnly disk.img` | **works, no root.** Produces `/dev/disk6` (FDisk_partition_scheme) and `/dev/disk6s1` (Windows_NTFS), both `br--r----- fd staff`, readable by the invoking user (uid 501). All four read tools work on the node. 0.305 s attach, 0.143 s eject. `hdiutil attach -nomount -readonly` does the same but is deprecated on 27.2 in favour of the `diskutil` form. |
| (b) `dd if=disk.img of=part.img bs=512 skip=2048 count=131072` | **works, no root, byte-identical** (SHA-256 of the extract equals the original partition image). 0.87 s for 64 MiB. Costs disk space equal to the partition. |
| (c) an offset option in the tools | **does not exist.** No `--offset` in any of the seven tools (checked `--help` and the sources). Pointing `ntfsls` at `disk.img` gives `NTFS signature is missing`, exit 2. |

**Least bad: (b) extract, then run the tools on the extract.** It never enters
the kernel filesystem stack, never hands the image to a third-party NTFS
driver, leaves no system state, and cannot be probed by DiskArbitration. Route
(a) is the fallback when the extra space is unacceptable — but on a host with an
NTFS kext loaded (as here) it is exactly the "raw images may still be probed by
DiskArbitration" case §8 calls out; `--noMount` did hold in this test and
nothing appeared in `mount`.

Either way, `ntfscluster` reports **volume-relative** cluster numbers. Convert
whole-disk mapfile offsets by subtracting the partition offset first.

## Damage attribution recipe

```sh
# 0. geometry — never assume the cluster size
ntfsinfo -m image.img | grep 'Cluster Size'          # 4096 in the fixture
ntfsinfo -m image.img | grep -E 'Volume Size|Free Clusters'

# 1. file -> extents (VCN, LCN, Length in clusters)
ntfscluster -F /media/big.bin image.img
#              VCN     LCN     Length
#                0    2153      512
#              512     537     1514
#             2026    3689       22

# 2. cluster range -> owners, including metadata and multiple files
ntfscluster -c 8725-8788 image.img
# Searching for cluster range 8725-8788
# Inode 77 /media/clip.dat/$DATA
# * one inode found

# 3. unowned range is not an error
ntfscluster -c 4000-4010 image.img
# * no inode found          (exit 0)
```

No `-f` is needed on an image file; `-f` only bypasses the "volume is in use"
/ "unclean journal" refusal and never grants write access (see below).

Exact maths used by the harness (`tools/damage.sh`), given a ddrescue mapfile
whose `-` extents are **device-absolute** byte ranges:

```python
C = cluster_size                      # from ntfsinfo, 4096 here
P = partition_offset                  # 2048 * 512 = 1048576 here, 0 for a partition image
first = (byte_pos - P) // C           # round the start down
last  = ((byte_pos - P) + byte_len - 1) // C   # round the end up
range = f"{first}-{last}"
```

Mapfile used (status `-` = bad sector), written by hand in the documented
format and validated by letting GNU ddrescue 1.30 parse it
(`ddrescuelog -t map` reported `bad-sector: 262144 B, in 1 area(s)`):

```
# Mapfile. Created by hand for the disktriage NTFS spike
# Command line: simulated mapfile, no device was read
# Start time:   2026-11-06 23:10:00
# Current time: 2026-11-06 23:20:00
# Finished
# current_pos  current_status  current_pass
0x00000000     +               1
#      pos        size  status
0x00000000  0x02215000  +
0x02215000  0x00040000  -
0x02255000  0x01DAB000  +
```

The test: `clip.dat` at LCN 8725 length 64 → bad bytes `0x02215000 + 0x40000`
→ clusters 8725–8788 → `ntfscluster -c` named `/media/clip.dat`. The same
recipe was repeated through the whole-disk path (offset 1048576 subtracted,
tools run on the attached node) and named the same file.

## Robustness

Exit codes recorded directly on the command (never through a pipe). "silent"
means exit 0 with no error on stderr.

| scenario (64 MiB image) | ntfsinfo -m | ntfsls -l | ntfscat file | ntfscluster -c | ntfsclone |
|---|---|---|---|---|---|
| healthy | 0 | 0 | 0 | 0 | 0 |
| file data zeroed, whole extent | 0 | 0 | **0, silent** — correct length, all zeros | 0, names the file | 0 |
| file data zeroed, 16 of 64 clusters | 0 | 0 | **0, silent** | 0, names the file | 0 |
| directory `$I30` zeroed (`/media`) | 0 | **0, silent, truncated listing** (`/media` shows 1 of 31 entries; "Corrupt index block signature" on stderr) | 1, `Couldn't open inode: No such file or directory` | 0, `Inode 66 /media/$INDEX_ALLOCATION($I30)` | 0 |
| `$MFT` records 0–3 zeroed | 1 | 2 | 1 | 1 | 1 |
| partition boot sector (512 B) zeroed | 1 | 2 | 1 | 1 | 1 |
| image truncated to 32 MiB | 0 (partial, logfile read error on stderr) | 0, partial listing | 1, `ntfs_pread failed: Input/output error` | — | — |
| 64 MiB of `/dev/urandom` | 1 | 2 | 1 | 1 | 1 |

Notes on the failures: mount-level failures are loud and consistent —
`NTFS signature is missing` (exit 1, except `ntfsls` which returns **2**),
`Record 0 has no FILE magic (0x0)` + `Failed to load $MFT: Input/output error`
+ `NTFS is inconsistent. Run chkdsk /f` for MFT damage. Nothing hung; the
slowest probe was `ntfsclone` of the whole volume at 0.264 s.

**No backup-boot-sector fallback.** With the 512-byte partition boot sector
zeroed, every tool refuses to open the volume, even though the backup boot
sector is intact at the last sector. There is no such fallback anywhere in
`libntfs-3g` and `ntfsfix -n` cannot reach it either (`Mounting
volume... NTFS signature is missing. FAILED`, exit 1). A single bad sector at
offset 0 costs the whole inspection, which is the opposite of what triage
wants.

The dangerous row is the first one: damaged *data* is indistinguishable from
zeroed data. Attribution must therefore be mapfile-driven, never
`ntfscat`-driven, and a copy's hash only proves it matches the image.

## Read-only guarantees

- Source: `ntfsls`, `ntfscat`, `ntfsinfo` and `ntfscluster` all call
  `utils_mount_volume(device, NTFS_MNT_RDONLY | (force ? NTFS_MNT_RECOVER : 0))`.
  `-f/--force` adds only `NTFS_MNT_RECOVER` — it bypasses the "volume is in
  use" / "unclean journal" refusal, it does not request write access. There is
  no flag that makes them write; no flag is needed to keep them read-only.
  `ntfsclone` mounts its source `NTFS_MNT_RDONLY` too and writes only its
  `-o`/`-O` target.
- Empirical: `chmod 400` image, all four tools exit 0, `ntfscat` SHA-256 still
  matches, `mtime` and mode unchanged (`stat -f %m` identical before/after).
  `ntfsinfo -m`, `ntfsls -lR`, `ntfscluster -F/-c` left both fixture images'
  size, mode and mtime untouched.
- The writers in this set are `mkntfs`, `ntfscp`, `ntfsfix` (and
  `ntfsclone -O` on its own output). They are only ever pointed at our own
  fixture or at a copy; `ntfsfix` is a repair tool and belongs in the hand-off
  text, not the inspection path.
- The fixture helper `captures/ntfs-spike/tools/nfixture.c` is the one thing
  that opens an image read-write (libntfs-3g, `NTFS_MNT_NONE`) — it exists only
  because ntfsprogs has no `mkdir`/`rm`, and it is scratch, not product.

## Licence note

`ntfsprogs` tools are GPL-2.0-or-later; `libntfs-3g` is LGPL-2.0-or-later. Both
are fine to **invoke as subprocesses**, exactly as §8 already treats ddrescue:
no derivative work, no linking into `DiskTriageCore`. Shipping the binaries
inside the app would trigger GPL compliance (source offer, notices) and is not
a decision this spike should make; if we do ship them, the static build above
is the relocatable form. Do not link `libntfs-3g` into the core library.

## Open problems

- **MFT damage kills attribution entirely.** When the bad extents include
  `$MFT` records that libntfs needs in order to mount, `ntfscluster -c` exits 1
  and nothing is attributable. §8's "no flag-everything fallback" rule means
  those files must be reported as unattributed, which is honest but is the case
  most likely to matter.
- **One range per subprocess.** `ntfscluster -c` accepts a single `a-b` range
  (comma lists are rejected: `Invalid number '8788,'`), so 447 mapfile extents
  become 447 invocations. At 36 ms each on this image that is ~16 s — but that
  number is for a 64 MiB volume with 52 files and **must not be extrapolated**;
  no large-volume timing was taken. **UNVERIFIED:** cost and behaviour at
  realistic inode counts.
- **Silent partial success.** `ntfsls` exits 0 while omitting most of a
  directory whose index block is corrupt, and exits 0 on a truncated image
  while listing only what fits. Any "list the volume" step must not treat exit
  0 as a complete answer.
- **No backup boot sector fallback** (above). A 512-byte hole at offset 0
  turns a recoverable volume into an unopenable one.
- **Attach versus third-party drivers.** `diskutil image attach --noMount`
  worked and did not mount on this host, but this machine has a third-party
  NTFS kext loaded and macFUSE installed. **UNVERIFIED:** whether a driver that
  claims the volume can still grab it during attach on a machine where the
  mount guard is not running.
- **Path-level identity.** Extraction is by UTF-8 path
  (`résumé-日本語.txt` round-tripped and hashed correctly), but macOS name
  normalisation (`nfconv`, on by default on Darwin) sits in the library; a
  caller should key off inode numbers from `ntfsls -i` / `ntfscluster`, not off
  names it re-derived itself. **UNVERIFIED:** behaviour on names that differ
  only by normalisation form.
- **ntfsclone `--rescue` is not an integrity signal.** It exited 0 and cloned a
  volume whose `/media` index block was zeroed. Useful for making a metadata
  copy, useless as a verdict.
- Not tested at all: volumes with compression, sparse files, alternate data
  streams, hibernated Windows volumes, sector sizes other than 512. Only
  macOS 27.2/arm64 and ntfs-3g 2026.9.28 were exercised.

---

## Row 11 (synthetic): boot-sector restore and scale

Status: spike result, 2026-11-07. The real MiNaH image no longer exists, so P0
row 11 is answered on **synthetic** images: `plain.img`/`part.img` (64 MiB,
4 KiB clusters, 52 files), `disk.img` (80 MiB, MBR, one 0x07 partition of
131072 sectors at LBA 2048), and two 2 GiB volumes built here. Everything was
run on this host under `captures/ntfs-spike/row11/` (gitignored). No `sudo`, no
mount, no `diskutil` except one `image attach --noMount --readOnly` of a copy.
Only explicit working copies were written; the fixtures and the original images
were never modified. Times are wall clock, measured around the child process.

### A1. Baseline: the damaged copy fails every command

`dmg.img` is a copy of `damaged-bootsec.img` (volume sector 0 zeroed).

| command on `dmg.img` | exit | ms | message |
|---|---|---|---|
| `ntfsinfo -m` | **1** | 9.3 | `NTFS signature is missing.` / `Failed to mount: Invalid argument` |
| `ntfsls -l` | **2** | 17.3 | same, and nothing on stdout |
| `ntfscat /docs/readme.txt` | **1** | 9.6 | same |
| `ntfscluster -c 8725-8788` | **1** | 9.2 | same |

### A2. The backup boot sector is the last sector of the *volume*

On `plain.img` the 512 bytes at byte offset 67108352 (sector 131071, the last
sector of the 64 MiB file) are **byte-identical to sector 0** (SHA-256
`4770ab54…8ffd65` for both). Same on `part.img` at the same offset. OEM ID is
`NTFS    `, bytes/sector `0x0200` = 512, sectors/cluster 8, boot signature
`55 AA`, hidden sectors 0 (`plain.img`) / 2048 (`part.img`) — the two fixtures
differ from each other only in that field, and each one's backup matches its
own primary.

Two facts that decide the offset formula:

- **`mkntfs` reserves the last sector.** Its BPB `total_sectors` field reads
  131071, while the file/container holds 131072 sectors. `mkntfs.c`
  (`create_backup_boot_sector`) writes at
  `(num_sectors + 1) * sector_size - 512` after subtracting the reserved
  sector, i.e. at the **end of the container**, one sector past the size the
  BPB declares. Deriving the backup position from BPB `total_sectors` would
  read the wrong sector here.
- **On a whole-disk image it is the last sector of the partition, not of the
  disk.** In `disk.img` the backup is at `P + V - 512` =
  1048576 + 67108864 − 512 = **68156928** (sector 133119) and equals the
  primary at `P`. The disk's absolute last sector (83885568) is zeros. Writing
  that sector over the primary gives back `NTFS signature is missing`, exit 1 —
  which is exactly why the OEM/sector checks below are not optional.

`ntfsfix.c` itself tries "the last sector of the partition (expected location)"
first, then the last sector the bad boot sector claims, then truncation
(`try_alternate_boot`).

**Formula, for a volume in a partition:**

```
backup_offset = partition_offset + partition_length_bytes - 512
```

with `partition_offset = start_lba * sector_size` and `partition_length_bytes =
num_sectors * sector_size` from the MBR/GPT entry (not from the BPB). For a bare
partition image, `partition_offset = 0` and `partition_length_bytes =
file_size`.

### A3. Restore on a working copy works, plain and offset

Plain image: copy `dmg.img` → `dmg-restore.img`, then

```sh
dd if=dmg-restore.img of=bootbackup.bin bs=512 skip=131071 count=1
dd if=bootbackup.bin of=dmg-restore.img bs=512 count=1 conv=notrunc
```

| check on the restored copy | result |
|---|---|
| `ntfsinfo -m` | **0**, 10.6 ms, `Volume Flags: 0x0000`, cluster 4096 |
| `ntfsls -lR` | **0**, 11.0 ms, diff against the undamaged listing = **0 lines** |
| `ntfscat /media/big.bin` | **0**, SHA-256 `cf11c5ec…b9886` = `work/plain/big.bin` |
| `ntfscat /docs/readme.txt` | **0**, SHA-256 `7d423d80…49971` = the source file |
| `ntfscluster -c 8725-8788` | **0**, `Inode 77 /media/clip.dat/$DATA` |

Offset image: copy `disk.img` → `disk-work.img`, zero sector 2048, extract the
partition with `dd bs=1m skip=1 count=64` → baseline fails (1 / 2 / 1). Restore
from sector 133119 into sector 2048, re-extract → `ntfsinfo` **0** (10.1 ms),
`ntfsls -lR` **0** with a 0-line diff against `part.img`, `ntfscluster -c`
**0** naming `/media/clip.dat`, and `ntfscat /media/big.bin` hashes to
`cf11c5ec…b9886` = `work/part/big.bin`. The attached-node route also works on
the restored whole-disk copy: `diskutil image attach --noMount --readOnly`
produced `/dev/disk8s1`, `ntfsinfo`/`ntfscluster` exited 0 on it, `mount`
showed nothing, `diskutil eject` succeeded.

### A4. Both boot sectors gone: no restore is possible

Copy of `dmg.img` with the last sector zeroed as well:

| command | exit | output |
|---|---|---|
| `ntfsinfo -m` | **1** | `NTFS signature is missing.` |
| `ntfsls -l` | **2** | same |
| `ntfscat` | **1** | same |
| `ntfscluster -c` | **1** | same |
| `ntfsfix -n` | **1** | `Mounting volume... FAILED` / `Attempting to correct errors... FAILED` / `Trying the alternate boot sector` |
| `ntfsfix` (real) | **1** | adds `Unrecoverable error`, `Volume is corrupt. You should run chkdsk.`; image SHA-256 **unchanged**, nothing written |

So the tool can state "cannot restore: both the primary and the recovery boot
sector are unreadable" from a single failed attempt — and it must not retry the
write.

### A5. What `ntfsfix` actually does

`ntfsfix --help`: `-b` clear bad sectors, `-d` clear dirty, `-n` no action.
On a **copy** of the damaged image:

```
$ ntfsfix dmg-fixed2.img
Mounting volume... FAILED
Attempting to correct errors... FAILED
Trying the alternate boot sector
The alternate bootsector is usable
Rewriting the bootsector
The boot sector has been rewritten

Processing $MFT and $MFTMirr...
Reading $MFT... OK
Reading $MFTMirr... OK
Comparing $MFTMirr to $MFT... OK
Processing of $MFT and $MFTMirr completed successfully.
Setting required flags on partition... OK
Going to empty the journal ($LogFile)... OK
Checking the alternate boot sector... OK
NTFS volume version is 3.1.
... was processed successfully.
```

exit **0**, 33.0 ms. It **does** restore from the backup: the 512 bytes it
writes at offset 0 are byte-identical to the original backup sector, and the
backup sector itself is left untouched. But it writes more than that: 169 bytes
differ from the damaged copy in total — the boot sector (0–211, 510–511), four
bytes inside the `$Volume` MFT record (19504–20478, the dirty flag) and four
bytes inside `$LogFile` (33553456–33554430, the emptied journal). The volume
comes back **dirty** (`Volume Flags: 0x0001 DIRTY`), so every read tool then
refuses:

- `ntfsinfo` exit 1 / `ntfsls` exit 2 / `ntfscluster` exit 1, all with
  `Volume is scheduled for check. Please boot into Windows TWICE, or use the
  'force' option.`
- with `-f` they exit 0 and `ntfscat -f /media/big.bin` still hashes to
  `cf11c5ec…b9886`.

`ntfsfix -n` on the same copy exits 1 and writes nothing (SHA-256 unchanged):
`The startup data can be fixed, but no change was requested`.

**Conclusion: `dd` is the better restore.** It is 2 subprocess-free writes, it
does not set the dirty flag, and it does not touch `$MFT`/`$LogFile`. `ntfsfix`
is a repair tool for the hand-off, not for inspection — as §8 already says.

### A6. Minimal safe restore procedure

1. Refuse unless the caller explicitly asked, and only on a **copy**; record
   the source image's SHA-256/size before and after and assert unchanged.
2. Compute `backup_offset` from the partition table (A2), `stat` the copy, and
   require `backup_offset + 512 <= file_size`.
3. Read exactly 512 bytes; a short read is a failure, not partially usable.
4. Validate before writing: `bytes[3:11] == "NTFS    "`, bytes/sector at 0x0B
   in {512, 1024, 2048, 4096} and equal to the sector size known from the
   volume, sectors/cluster at 0x0D a power of two in 1..128, signature
   `55 AA` at 0x1FE. Optionally require `total_sectors × bytes_per_sector` to
   be within one sector of the partition length (allow the `mkntfs` reserved
   sector). If any check fails: report "cannot restore" and stop.
5. Write the 512 bytes at `partition_offset` with `conv=notrunc`; never extend
   or truncate the file.
6. Verify afterwards: `ntfsinfo -m` exits 0 and reports the expected cluster
   size and volume size; only then run the rest of `inspect`. If it still
   fails, the damage is beyond the boot sector (e.g. `$MFT`) and the result is
   volume-level with the reason.

### B1. A 2 GiB volume with realistic file counts

| image | size | clusters | files | notes |
|---|---|---|---|---|
| `plain.img` | 64 MiB | 16383 | 52 | the existing fixture |
| `big.img` | 2 GiB sparse | 524287 | 2000 small + 100 × 1–20 MiB | 1.0 GiB used; `mkntfs -F -Q -q` = 28.6 ms, 11 MiB allocated |
| `bigempty.img` | 2 GiB sparse | 524287 | 10001 small | 55 MB used; adding the 10 000 files took 118.8 s |

Population with `ntfscp`, no mount: 2000 small files in 22.8 s (11.4 ms/file),
100 large files in 4.4 s (43.8 ms/file), **27.2 s total**, 0 failures. No
counts were reduced.

### B2. `ntfscluster -c` cost scales with the MFT, not the volume

Single cluster range, repeated (mean / median over the loop):

| image | inodes | 1 run | 10 runs | 100 runs | median |
|---|---|---|---|---|---|
| `plain.img` 64 MiB | 52 | 9.7 ms | 7.0 ms | 6.9 ms | 6.8 ms |
| `big.img` 2 GiB, 1 GiB data | 2 100 | 13.7 ms | 10.9 ms | 10.9 ms | 10.7 ms |
| `bigempty.img` 2 GiB, empty | ~30 | 7.3 ms | 6.8 ms | 6.9 ms | 6.7 ms |
| `bigempty.img` + 10 k files | 10 001 | — | 27.9 ms | — | 25.5 ms |

`t ≈ 6.3 ms + 2.0 µs × inodes`. The 2 GiB volume with 30 inodes costs the same
as the 64 MiB volume: **volume size is irrelevant, MFT size is the cost**. Real
batches with distinct ranges: 200 extents = 3.31 s (16.6 ms/call), 447 extents
= 5.92 s (13.3 ms/call) on the 2 100-inode image.

`-I <inode>` and `-F <file>` are different: **flat ~7 ms** at 52, 2 100 and
10 001 inodes (7.2 / 7.4 / 7.1 ms), because they look up one inode instead of
scanning the MFT.

### B3. Alternatives to one subprocess per extent

(a) **One `-c min-max` over the whole span** — `-c 73962-303000` on `big.img`:
15.2 ms, 3 418 B, 105 `Inode …` lines. It prints one line per *run* that
intersects the range and is fast, but it **cannot be used for attribution**: it
also named `/large-050.bin` (LCN 195696), which was not a bad extent — every
file in the good gaps between bad extents is reported. It also has no numeric
output, so the caller cannot subtract the gaps without more calls.

(b) **`-f` / other modes** — `-f` changes nothing on an image (same output,
11.3 ms); it only bypasses the dirty-volume refusal. `-i` prints volume info
only. `-s` is `-c` in sectors (`-s 1800000` = 18.0 ms). `-I`/`-F` are one
inode/file. A comma list is rejected (`Invalid number '74022,'`, exit 1).

(c) **One pass with `ntfsinfo`/`ntfscat`** — `ntfsinfo --help` has only
`-i`/`-F`/`-m`; `-m` prints no runs (0 `VCN` lines) and `-i` is one inode at
8.2 ms. `ntfscat -a 0x80 -i 2066` dumps the *file bytes* (1 060 921 bytes for
the 1 MiB file), not its runs. Neither offers a bulk mode.

**But there is a true single pass: `ntfscluster -c 0-<nr_clusters-1> -v`.**
`-v` makes `cluster_find` print `VCN LCN Length` for every run of every inode
it scans, before the range filter (`cluster.c`); the range `0..last` also makes
it print the matching `Inode N /path/$ATTR` line after each run. One
invocation therefore returns the complete extent map:

| image | time | output | runs |
|---|---|---|---|
| `plain.img` (52 inodes) | 11.4 ms | 10 746 B | 46 |
| `big.img` (2 100) | 37.4 ms | 377 255 B | 1 778 (1 760 inodes) |
| `bigempty.img` (10 001) | 144.8 ms | 1 780 824 B | 8 262 |

`t ≈ 10 ms + 13.5 µs × inodes`, ~215 B per run. Parsing it and intersecting
locally reproduced the per-extent answers exactly on spot checks: 73962 →
`/large-000.bin`, 195696 → `/large-050.bin`, 303627 → `/large-099.bin`,
400000 → `* no inode found`; cluster 0 → `Inode 7 /$Boot/$DATA`.

### B4. Recommendation and cap

- **Primary: one `ntfscluster -c 0-(nr_clusters-1) -v` per image, parsed
  streaming, intersected in-process with the mapfile's cluster ranges.** It is
  exact (no gap false positives), independent of the extent count, and pays
  for itself above ~4 extents at 2 100 inodes and ~6 at 10 001 (37.4/10.9 and
  144.8/25.5). 447 extents would be 5.92 s one-by-one and 37 ms in one pass
  (~160×).
- **Guards for that pass:** a hard timeout (120 s), a cap on parsed runs
  (e.g. 200 000 runs ≈ 43 MB by the measured 215 B/run), and a fallback that
  reports volume level if either trips. This is not an extent cap; it is a
  work cap.
- **Fallback when the pass is unavailable (dirty volume it cannot force, or
  output cap hit): per-extent `-c`, cap 200 extents, and additionally cap by a
  30 s budget — `cap = min(200, 30 000 / per_call_ms)`, with `per_call` from
  one probe call on that image.** Measured: 3.31 s for 200 extents at 2 100
  inodes, ~5.1 s at 10 001. At 1 M inodes the model gives ~2 s/call, so the
  time budget would reduce the cap to ~15 (**UNVERIFIED**, extrapolated).
- **Never use the merged span for attribution**; it over-attributes every file
  in the good gaps. `-I`/`-F` are viable for the second stage of a
  "span → candidate inodes → per-inode runs" pipeline (flat ~7 ms each), but
  the `-v` pass makes that stage unnecessary.
- Restoring the boot sector does not help a volume whose `$MFT` is damaged;
  those stay volume-level (A6 step 6).

**UNVERIFIED:** backup placement/fields on a Windows-formatted volume (only
`mkntfs` images here), 4 Kn volumes, the `-v` output format across other
ntfs-3g versions, and all extrapolation past 10 001 inodes.
