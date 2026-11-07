# 0010. Mapfile accounting: failed is not bad (P3b follow-up)

Status: accepted
Date: 2026-11-07

## Context

The first real `disktriage image --limit 10` run on the failing MiNaH drive
(WD3200BJKT, 131 pending sectors) printed `BAD 0 bytes` and `0 unreadable
extents` while its mapfile held 12 `*` extents of 64 KiB. The statuses are not
interchangeable: in GNU ddrescue 1.30's mapfile, `?` is non-tried, `*` failed
during copying and is not yet trimmed, `/` is trimmed but not scraped (both
contain read errors), `-` is a confirmed bad sector, and `+` is finished.

## Decision

- **Four quantities, never merged.** `MapfileSnapshot` keeps rescued (`+`),
  untried (`?`), failed (`*` + `/`) and bad (`-`) apart, each with its byte
  total and extent count (`failedBytes`, `failedExtents`, `badBytes`,
  `badExtents`; the older `nonTrimmedBytes`/`nonScrapedBytes` remain).
- **The summary never hides damage behind `BAD 0`.** The human summary always
  prints `FAILED  X bytes in N extents (read errors seen; not yet trimmed or
  scraped)` and `BAD  X bytes in N extents (confirmed)`. The live progress line
  carries the failed bytes and extent count too. JSON keeps `bad_bytes` and
  `remaining_bytes`/`remaining_extents` and adds `failed_bytes`,
  `failed_extents` and `bad_extents`; the old keys stay.
- **`inspect` and `copy` count failed and bad together as unreadable.** An
  extent with a read error is unreadable so far whether or not ddrescue has
  isolated it, so `unreadable_extents`/`unreadable_bytes` are failed + bad.
  The damage line also shows the split (`(12 failed, 0 confirmed bad)`), and an
  incomplete mapfile adds: failed extents may shrink after trimming and
  scraping. The JSON damage section adds `failed_extents`, `failed_bytes`,
  `bad_extents` and `bad_bytes`. `copy` writes the same four fields into the
  manifest's damage section.
- **The partial-image clamp is unchanged (REQ-0108).** Every accounting runs
  inside `[0, limit)` exactly as before; failure simply has its own bucket now.
  The real MiNaH mapfile measured 12 failed extents (786,432 bytes), not 13.

## Consequences

- **Fixture and reason.** `Tests/Fixtures/minah-partial-me.mapfile.txt` is the
  real run with its local paths redacted; `mapfile-trimmed-bad.mapfile.txt` is
  the same drive after trimming (12 `-` extents) and
  `mapfile-nonscraped.mapfile.txt` is the `*`/`/` table. The expectations come
  from the status meanings above, not from the parser.

## Requirements

- REQ-0172
- REQ-0177
