# Collector observations — P1c

What the two verifiable read-only probes actually did on the internal disk
(`disk0`, Apple Silicon, macOS 27.2). No `sudo`, no writes, no mount, no raw
device read. Recorded 2026-11-06; redactions are marked `REDACTED`.

## 1. `smartctl --json=o -i /dev/disk0`

| | |
|---|---|
| binary | `/opt/homebrew/bin/smartctl` 7.5 r5714 (Homebrew, arm64) |
| exit code | **0** |
| stderr | empty |
| output | 1721 bytes of JSON (stdout), no prompts |
| root | **not required** on this internal NVMe |

Shape (keys observed; values elided where redacted):

```json
{
  "json_format_version": [1, 0],
  "smartctl": {
    "version": [7, 5],
    "svn_revision": "5714",
    "platform_info": "Darwin 27.2.0 arm64",
    "argv": ["smartctl", "--json=o", "-i", "/dev/disk0"],
    "exit_status": 0
  },
  "device": { "name": "/dev/disk0", "type": "nvme", "protocol": "NVMe" },
  "model_name": "APPLE SSD AP0256Q",
  "serial_number": "REDACTED",
  "firmware_version": "REDACTED",
  "nvme_number_of_namespaces": 3,
  "smart_support": { "available": true, "enabled": true }
}
```

Findings that matter for status mapping:

- Opening the internal NVMe does **not** need root and produced no `denied`.
  `denied` must therefore be reserved for a real spawn `EACCES`/`EPERM` (or a
  tool's own permission error), never inferred from the device type.
- `device.type` is `"nvme"` and `smart_support.available` is `true`; this is a
  recorded fact for this machine, not a claim about USB bridges.
- The tool's exit status is inside JSON (`smartctl.exit_status`) **and** in the
  process status; the two agree here (0). A parser must read the bitmask before
  deciding `ok`/`error`.
- No ATA attribute table is present for NVMe (`-A` would differ). Do not write a
  parser against this output; it is not the USB-HDD shape.

Redactions: `serial_number`, `firmware_version` (a firmware revision can be a
unit identifier). Nothing else was altered.

## 2. `/usr/bin/log show --last 1m --predicate 'eventMessage CONTAINS "medium error"'`

| | |
|---|---|
| exit code | **0** |
| stderr | empty |
| output | 341 bytes, header plus one line |
| privilege | none needed |

The whole body was:

```
Timestamp  Thread  Type  Activity  PID  TTL
<time>     0x…     Default 0x0     REDACTED  0  log: [com.apple.log:]
  log run noninteractively, parent: REDACTED (zsh), args: '/usr/bin/log'
  'show' '--last' '1m' '--predicate' 'eventMessage CONTAINS "medium error"'
```

Findings:

- On a healthy internal disk there are **no** medium-error events; exit 0 with
  an empty event list is a real `ok` with zero events, not `denied` and not an
  error.
- The one line is the `log` invocation itself: the predicate text appears in
  that event message, so the query matches its own process. A future parser
  must drop the `log run noninteractively`/self-argv line before counting
  events, or the collector will report one phantom "medium error" forever.
- `--last` is mandatory in the allow-list: an unbounded `log show` can walk the
  whole log and blow the timeout. `--predicate` is optional.
- Log retention was **not** measured here; it stays `log.window_hours = nil`
  until the bench records it (P0 row 3).

Redactions: serial/firmware above, PIDs and timestamps in the log line.

## 3. What was deliberately not built

Real USB-HDD output does not exist yet (bench Phase B). Parsers written against
guesses would violate "an absent signal is never a zero", so P1c ships no
parser for:

- `smartctl -d sat -a` on a USB bridge (ATA attributes, pending/reallocated,
  error log, overall status, per-bridge root/TCC behaviour);
- `ioreg -r -c IOBlockStorageDriver -k Statistics` (which counters are real is
  P0 row 2; until then `io.p0_validated` stays absent/false);
- unified-log medium-error/reset events (retention is P0 row 3);
- filesystem-driver inventory (`/Library/Filesystems`, `systemextensionsctl`);
- permissions probes (root / raw-read / removable volumes);
- filesystem inspection (image only, §8).

`Collector` is the seam (`Sources/DiskTriageCollectors/Collector.swift`) and
`DeviceCollector` is its only implementation. The others become real types when
their recordings land; until then `SignalSetBuilder` emits `unsupported` with a
reason and a `collector_notes` entry.

## 4. TODO before the SMART / I/O / log collectors

1. Record `smartctl --json=o -d sat -a /dev/diskN` for the control USB-HDD and
   for a MiNaH-style drive; store redacted JSON next to this note.
2. Decide the exit-status mapping (`smartctl.out.exit_status` bitmask: command
   line error vs device-open error vs SMART failure) and the `denied` mapping
   for a bridge that refuses `-d sat`.
3. Record `ioreg -r -c IOBlockStorageDriver -k Statistics` on the control disk;
   only then set `io.p0_validated` (P0 row 2).
4. Record a real medium-error burst from the unified log; keep the self-line
   filter and record retention for `log.window_hours` (P0 row 3).
5. Add collector-note reasons to the `SignalSet` contract. Schema v1 has no
   per-section `reason` field; P1c keeps reasons in
   `SignalSetBuilder.unsupportedReasons` and only the status in the JSON.
   Fixing that is a plan/contract change, not a collector change.
6. `device.block_size` is parsed and tested (`DeviceIdentity.blockSize`) but is
   not in the v1 `DeviceSignals` contract; it is not emitted into the JSON yet
   for the same reason.
