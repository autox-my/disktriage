# 0009. The stopped-DA rule reaches the rest of the image path (P3b follow-up)

Status: accepted
Date: 2026-11-07

## Context

The identity fix above left three `diskutil` calls on the same paths. P0 phase
C measured that a suspended `diskarbitrationd` makes every one of them hang, so
they now ask the same `DiskArbitrationProbe` the collector uses, and a timeout
still falls back once.

## Decision

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

## Consequences

- **Evidence.** `DISKTRIAGE_FORCE_IOREG=1` drives both destination paths on a
  healthy Mac. On the reference machine the old and new paths agreed:
  `/Users/fd/Projects/diskdoctor/captures/image-smoke/x.img` → `disk0` (APFS;
  the same volume and free-space reading), whole disks `disk0…disk7` in the
  same order, and the internal probe node `/dev/rdisk0` by both paths.
- **Unchanged.** With the daemon running, identity, enumeration and the
  destination walk still use `diskutil` first; the suite drives the whole
  `image --no-dry-run` flow with a fake ddrescue and asserts both the
  zero-diskutil stopped run and the diskutil-first running run.

## Requirements

- REQ-0166
- REQ-0169
- REQ-0170
