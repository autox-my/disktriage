# 0026. APFS multi-volume representation and `copy --volume`

Status: accepted
Date: 2026-11-08

## Context

An APFS image attaches as a **container**: `diskutil image attach --noMount
--readOnly` names the whole disk (`/dev/diskN`), the container partition
(`/dev/diskN s1`, `Apple_APFS`), a synthesized container (`/dev/diskN`,
`Apple_APFS_Container`) and one or more synthesized volumes (`/dev/diskN sM`,
`Apple_APFS_Volume`). The plan lists "multi-store APFS representation" as a
gap: the tool must not pretend a container is one volume. A 2 GiB synthetic
container held two volumes on this host; a 512 MiB one refused a second volume
(`-69493`).

## Decision

- **`inspect` lists every volume.** The report's `attach` object names the exact
  whole disk and the attach mode; `volumes[]` has one entry per mountable
  volume with `index` (1-based), `device`, `name`, `filesystem`, `encrypted`,
  `locked`, `status` (`ok | partial | error | timeout | locked`), the root and
  recursive entry counts, the directory count, `truncated` and a `reason`.
  Each volume is mounted read-only in turn and unmounted before the next; the
  whole disk is ejected once at the end. A locked volume is listed as `locked`
  and not mounted.
- **`copy` needs exactly one volume.** When the attach produces more than one
  volume of the selected filesystem, `copy` exits **30** and names every
  volume and the `--volume` values it accepts. It never guesses, never copies
  the first volume, and never merges volumes.
- **`--volume <name|index>`.** A positive integer is a 1-based index into the
  matching volume list; anything else is a name, matched exactly first and then
  case-insensitively only when that match is unique. An unknown, out-of-range
  or ambiguous selector is **30** with the available list. A single volume
  needs no selector; `--volume` on an NTFS image is a usage error (2).
- **Representation, not a new manifest.** The selected volume is reported in
  `copy`'s JSON as `volume` and in the human `VOLUME` line; the manifest keeps
  schema `disktriage.copy/1` and its existing keys, because the file entries
  and damage accounting did not change. Adding a manifest key would have forced
  a schema version bump for a display-only fact.
- **No per-file attribution.** The selected volume is still reported at volume
  level; `attribution.kind` is `none` with the `F_LOG2PHYS_EXT` reason (ADR
  [0025](0025-native-read-only-attach.md)).

## Consequences

- A multi-volume APFS image is inspectable as a whole and copyable one volume
  at a time. The live fixture is a 2 GiB APFS image with `DTAPFS1` and
  `DTAPFS2`; `DTAPFS2` alone carries `second/only-on-two.txt`, so the live test
  proves the selection, not just the refusal.
- A bare-partition image (no container) attaches as one whole disk that is both
  the volume and the detach target; the same report shape is used with one
  `volumes[]` entry.
- **Not verified:** APFS volumes with snapshots, roles or quotas; more than two
  volumes; a container whose volume list changes between attach and mount. The
  representation is deliberately the attach's own device list, not a name
  re-derived from `/Volumes`.

## Requirements

- REQ-0287
- REQ-0288
- REQ-0289
- REQ-0290
- REQ-0291
- REQ-0305
