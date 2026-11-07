# 0008. Identity while DiskArbitration is stopped (P3b follow-up)

Status: accepted
Date: 2026-11-07

## Context

`guard --suspend` and `image`/live `triage` used to be mutually exclusive: the
guard SIGSTOPs `diskarbitrationd`, and P0 phase C measured that `diskutil`
then hangs system-wide, while the device collector read identity through
`diskutil info -plist`. The collector now has an ioreg path that never waits on
a hung `diskutil`.

## Decision

- **The stopped-daemon probe reuses the guard's argv.** `pgrep -x
  diskarbitrationd`, then `ps -o stat= -p <pid>`, through the injected runner;
  both exact shapes are on the triage allow-list. Only a positive stopped
  state (`ProcessState.isStopped`, the same T-prefix rule the guard's suspend
  check uses) skips `diskutil`. A failed or unknown probe falls through to the
  normal `diskutil` path, so an unreadable state is never treated as a guard.
- **The ioreg path is two read-only shapes.** `ioreg -r -c
  IOBlockStorageDevice -w 0 -l` gives the device's `Device Characteristics`
  (product, vendor, serial, medium type), `Protocol Characteristics`
  (interconnect and location) and its whole-disk `IOMedia` child (`BSD Name`,
  `Size`, `Preferred Block Size`, `Whole`, `Removable`, `Ejectable`). When the
  block device exposes no serial, one further query, `ioreg -r -c
  IOUSBHostDevice -w 0 -l`, supplies the USB host device's `USB Serial
  Number`; the association is the same `BSD Name` in the same subtree, never
  order-based. `-t` is deliberately not used: it prints every ancestor's
  properties, which can exceed the runner's output cap before the device
  appears.
- **The source and the reason are recorded.** A `DeviceCollection` now carries
  `source: diskutil | ioreg` and, on the stopped path, the reason line
  `diskarbitrationd is stopped; diskutil skipped`. A `diskutil` timeout for any
  other reason also falls back once to ioreg and keeps the timeout as evidence
  (`diskutilTimeoutMs`, plus `timed out after N ms` in the reason); the run
  does not become exit 30 because identity succeeded, and a failed fallback
  keeps both failures.
- **Absent stays absent.** A serial the ioreg tree does not expose stays
  `nil`; the image confirmation then asks for `--confirm-size <GiB>` exactly as
  before. A hex-encoded USB serial is decoded only when every byte is printable
  ASCII (a real ASCII serial such as `0ba01062e2bc880e` is left alone), and an
  empty `Product Name`/`Vendor Name` is `nil`, not an empty value.
- **`DISKTRIAGE_FORCE_IOREG=1` is a test-only override.** It forces the ioreg
  path so a healthy Mac can exercise it without suspending a system daemon; it
  is not a supported CLI flag and is documented here only so the smoke result
  is reproducible. `triage --from` is untouched.

## Consequences

- **What is still not covered.** `enumerate()`/`list` now use the same ioreg
  path (see the follow-up below), but the ioreg identity still leaves
  `virtualOrPhysical` nil for a physical disk (only a synthesized APFS media
  is marked `Virtual`) and reports `media` as `unknown` when `Medium Type` is
  absent, which is the P0-measured USB case.

## Requirements

- REQ-0162
- REQ-0163
