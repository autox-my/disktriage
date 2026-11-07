# 0005. CLI decisions (P3c, `copy`)

Status: accepted
Date: 2026-11-07

## Context

`disktriage copy <image> --to <dir> [--mapfile <path>] [--json]
[--hash-image]` copies the **file tree** of an NTFS volume out of an image,
read-only, with a SHA-256 per file and a manifest. It builds on `inspect`'s
partition parse, NTFS tool policy, mapfile parser (including the sidecar
`limit_bytes` clamp) and absolute-path resolution; none of that is duplicated.

## Decision

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

## Consequences

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

## Requirements

- REQ-0125
- REQ-0126
- REQ-0127
- REQ-0129
- REQ-0136
