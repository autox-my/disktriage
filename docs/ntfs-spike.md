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
