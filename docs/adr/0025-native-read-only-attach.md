# 0025. Native read-only attach for APFS, HFS+, exFAT and FAT

Status: accepted
Date: 2026-11-08

## Context

`inspect` and `copy` detected APFS (`NXSB`), HFS+ (`H+`/`HX`), exFAT and FAT
from the image's own bytes and refused them with `native read-only attach not
implemented yet`, exit 30 (ADR [0004](0004-inspect-ntfs-read-only.md)). The plan
(diskdoctor.md §8 "Inspection") says the route is `diskutil image attach
--noMount --readOnly` (or `hdiutil attach -readonly -nomount`) of the image
file, then an explicit native read-only mount, never a writable third-party
driver. NTFS stays on the ntfs-3g userspace-tools path: macOS 27.2 has no native
NTFS mount (`docs/ntfs-spike.md`).

Measured on this host, macOS 27.2 arm64 (Xcode 27.2 / Swift 6.4.2), as uid 501,
no `sudo`:

| Fact | Measurement |
|---|---|
| Native filesystem bundles | `/System/Library/Filesystems` has `apfs.fs`, `hfs.fs`, `exfat.fs`, `msdos.fs` |
| Attach | `diskutil image attach --noMount --readOnly <image>` = 0.29–0.58 s for a 32–64 MiB image |
| Automount after attach | none: `mount | grep` was empty until the explicit mount |
| Explicit mount | `diskutil mount readOnly nobrowse -mountPoint <dir> <dev>` = 0.39–0.58 s, works without root |
| The `/sbin/mount` form | `mount -t exfat -o rdonly,nobrowse,noowners …` exits 71 without root (`Insufficient permissions`, `exfat filesystem is not available`) |
| Unmount / detach | `diskutil unmount <dev>` = 0.27–0.48 s; `diskutil eject <whole-disk>` = 0.23 s |
| Full cycle | attach + mount + list + unmount + detach ≈ 1.2–1.8 s for a 32–64 MiB image |
| Mount flags observed | `read-only`, `noowners`, `nobrowse`, `fskit`, mounted by the invoking user |
| Third-party driver | **not loaded on this host at measurement time**: `kmutil showloaded` listed no iBoysoft NTFS kext and `systemextensionsctl list` only Tailscale. The brief's iBoysoft kext was not present; attach of non-NTFS images was not interfered with |
| Whole-disk image | a GPT image attaches as `/dev/diskN` (scheme), `/dev/diskN s1` (partition); an APFS partition becomes a synthesized `/dev/diskN` container with `/dev/diskN sM` volumes |
| Bare-partition image | attaches as one whole disk `/dev/diskN` whose `FilesystemType` is the filesystem (`WholeDisk: true`); it is both the volume and the detach target |
| APFS multi-volume | a 512 MiB container refused a second volume (`-69493`); a 2 GiB container accepted `diskutil apfs addVolume` |
| Encrypted APFS | `diskutil info -plist` reports `Locked: true`; `diskutil mount` fails without prompting (`This is an encrypted and locked APFS Volume; use "diskutil apfs unlockVolume"`) |
| APFS mountpoint | `diskutil mount -mountPoint` is ignored for an APFS volume (it mounts under `/Volumes`); the fixture generator reads the real `MountPoint` from `diskutil info` |

## Decision

- **Route.** The image file is attached with exactly
  `diskutil image attach --noMount --readOnly <absolute-image>`. The explicit
  mount is exactly
  `diskutil mount readOnly nobrowse -mountPoint <absolute-dir> <device>`.
  Cleanup is exactly `diskutil unmount <device>` then
  `diskutil eject <whole-disk>`. `diskutil info -plist <device>` reads the
  volume name, `FilesystemType` and lock state; `hdiutil info` is used only to
  recover the disk of an attach that timed out.
- **No writable or third-party shape exists.** `CommandPolicy.native` permits
  exactly those argv shapes and no wildcard: no `/sbin/mount`, no
  `-mountOptions`, no `readWrite`, no `--force`, no `--stdinpassphrase`, no
  `diskutil apfs unlockVolume`, no kext load, no package install. The image is
  opened read-only everywhere; a test hashes it before and after.
- **Cleanup on every path.** A `NativeAttachmentLease` fixes the exact
  `/dev/diskN` the attach named. `cleanup()` is idempotent, unmounts the exact
  volume it attempted to mount, then ejects that exact disk, and is called from
  `defer`, from every error return, and from a `DispatchSourceSignal`
  SIGINT/SIGTERM handler. A mount attempt is recorded **before** the call, so a
  mount that times out and may have succeeded is still unmounted. An attach
  timeout recovers the disk from `hdiutil info` only by exact image-path match;
  if no disk is found, nothing is ejected (the leak guard then fails).
- **Timeouts.** Attach 30 s, `diskutil info` 15 s, mount 65 s (DiskArbitration
  may wait up to a minute), unmount 30 s, eject 30 s. Every call goes through
  `ProcessRunner` with a process-group `TERM`-then-`KILL`.
- **Encrypted volumes.** A `Locked: true` volume is never mounted and no
  passphrase is ever requested or passed. If every volume is locked, `inspect`
  and `copy` exit **30** with a message naming the volume and saying the tool
  never prompts for a passphrase. An encrypted but unlocked volume is mounted
  read-only like any other.
- **Damage.** The mapfile is read exactly as for NTFS (`--mapfile`, else
  `<image>.mapfile`, clamped by the sidecar's `limit_bytes`). Every output
  carries the volume-level damage section and the "unreadable regions are
  zero-filled" note. Per-file attribution is **not** implemented for these
  filesystems: `F_LOG2PHYS_EXT` is an open P0 item in diskdoctor.md §8, so the
  manifest says `attribution.kind = none` with that reason and no file carries
  an `integrity` value. A native mount of a damaged image can return zeros
  silently, which is exactly why the mapfile, not the mount, is the evidence.
- **Exit codes.** `inspect`: 0 inspected with no damage note, 1 damage or a
  partial volume, 30 a precondition/tool/attach error. `copy`: 0 copied with
  agreeing hashes and no damage, 1 damage or a partial copy, 30 a
  precondition/tool/attach error. `--json` keeps the existing sections and adds
  `attach` and `volumes`; the manifest schema stays `disktriage.copy/1`.
- **NTFS is unchanged.** A `.ntfs` image still goes to the ntfs-3g tools and
  never enters this path; an unknown boot sector stays an NTFS candidate so the
  MiNaH boot-sector case is still reported or restorable.

## Consequences

- `inspect` and `copy` now work on synthetic APFS, HFS+, exFAT and FAT images
  through the real `diskutil` on this host. The live tests copy the fixture into
  a test temp directory, attach it, and assert no image or mountpoint is left.
- The gate gained a native leak guard (ADR [0027](0027-native-attach-leak-guard.md)):
  an image whose path contains `disktriage` still in `hdiutil info`, or a
  `disktriage-mount-*` line in `mount`, is a FAIL (1).
- **Deliberately not built:** per-file attribution for native filesystems
  (`F_LOG2PHYS_EXT`), extraction of a bare APFS partition fixture (the whole-disk
  APFS image covers the container case), and a writable or repair path. The
  fixture generator is the only code that attaches an image read-write, and only
  to images it just created; it is not product code.
- **Not verified:** a host with a third-party NTFS kext loaded (the brief's
  iBoysoft kext was absent here); a FileVault HFS+ (CoreStorage) volume; APFS
  volumes with snapshots; a damaged native image whose metadata makes the
  mount itself fail (the mapfile-only damage fixture proves the reporting path,
  not a real zero-filled metadata failure). These are named gaps, not silent
  assumptions.
- Recommended plan changes (not made here, because diskdoctor.md is the
  human's): the Inspection bullet that says "planned, not yet built", the
  README limits line "v0.1 inspect/copy is NTFS only", and REQ-0088's wording if
  the plan wants one claim covering both routes.

## Requirements

- REQ-0265
- REQ-0266
- REQ-0267
- REQ-0268
- REQ-0269
- REQ-0270
- REQ-0271
- REQ-0272
- REQ-0273
- REQ-0274
- REQ-0275
- REQ-0279
- REQ-0280
- REQ-0281
- REQ-0282
- REQ-0283
- REQ-0284
- REQ-0285
- REQ-0286
- REQ-0292
- REQ-0293
- REQ-0294
- REQ-0295
- REQ-0296
- REQ-0297
- REQ-0298
- REQ-0299
- REQ-0300
- REQ-0301
- REQ-0302
- REQ-0303
- REQ-0304
- REQ-0306
- REQ-0307
- REQ-0308
- REQ-0309
- REQ-0310
- REQ-0311
- REQ-0312
- REQ-0313
- REQ-0314
- REQ-0315
- REQ-0316
- REQ-0317
- REQ-0318
- REQ-0319
- REQ-0320
