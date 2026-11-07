# 0004. CLI decisions (P3c, `inspect`)

Status: accepted
Date: 2026-11-07

## Context

`disktriage inspect <image> [--mapfile <path>] [--json]
[--restore-boot-sector --to <working-copy>]` is the read-only NTFS inspection
from diskdoctor.md §6 and §8. v1 is **NTFS only**; the other filesystems the
plan names are detected and refused, not attached (a plan gap, below).

## Decision

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

## Consequences

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

## Requirements

- REQ-0112
- REQ-0117
- REQ-0121
- REQ-0122
- REQ-0123
- REQ-0124
- REQ-0133
- REQ-0134
- REQ-0137
- REQ-0142
