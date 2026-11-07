# 0014. Allocation-aware NTFS stage 0 is a pure library (v3.8)

Status: accepted
Date: 2026-11-07

## Context

`diskdoctor.md` §8's "Allocation-aware order for NTFS" now has its pure core in
`DiskTriageCore`: boot geometry, the stage-0 read plan, MFT record parsing, the
`$Bitmap` decoder, the allocation domain and a ddrescue domain-mapfile writer.
No CLI, ddrescue invocation or staging is added here; a later change wires it
into `image`. The library does no I/O,
starts no process and reads no file.

## Decision

- **Boot geometry.** `NTFSBootGeometry.parse` reuses the inspect work's rules
  through a new typed `NTFSBootSectorRules.validateTyped` (the old `validate`
  is now its text projection, so there is one implementation). It adds the
  `$MFT`/`$MFTMirr` LCNs and the signed record-size encoding (`-n` = `2^n`
  bytes, positive = clusters). An MFT LCN at or past the volume end is a typed
  failure. `NTFSBootGeometry.select` validates the backup at
  `partition_offset + partition_length_bytes - 512` and reports
  `primary | backup`; two bad sectors are `.noUsableBootSector`.
- **Stage-0 plan.** `NTFSStage0ReadPlan.plan` is two-step. Before geometry it
  lists the partition table (including the GPT backup header and entry array
  when `deviceSize` is known), the primary boot sector and the backup boot
  sector. Once geometry exists it appends the first 16 MFT records at the MFT
  LCN. The caller performs the reads.
- **MFT records.** `NTFSMFTRecord.applyFixups` verifies every sector tail
  against the USA and restores the originals; a mismatch is a torn record and
  a typed failure. `dataAttribute` decodes an unnamed `$DATA`: resident bytes
  or a non-resident run list. `NTFSRunList` reads the mapping pairs with
  signed offset deltas and sparse runs, and rejects overlap, a run past the
  volume end and fragmentation over the cap. An `$ATTRIBUTE_LIST` is a typed
  `unsupported`, never followed.
- **`$Bitmap`.** Bits are least-significant first; used clusters are
  coalesced; bits past `total_clusters` are ignored. A short bitmap is a typed
  failure. `$Bitmap`'s last byte in the spike image has bit 16383 set past a
  16383-cluster volume; counting it would report 12309 used clusters, not the
  tool's 12308.
- **Domain and free space.** `NTFSAllocation.allocationDomain` unions every
  `$MFT` run, the 16-record metadata region and the used cluster runs, adds
  the partition offset, merges/sorts and clips to the partition, and returns
  the complement for stage 2. `NTFSAllocation.evaluate` is the one-call stage-0
  path; when the MFT record, bitmap record or bitmap bytes are unavailable it
  returns `.unknown(reason)`. "Unknown" is never "everything free", and the
  writer only accepts a domain, so a failed stage 0 cannot produce a mapfile
  that skips free space.
- **Domain mapfile.** `DdrescueDomainMapfile.render` writes `# Mapfile. Created
  by disktriage`, a `current_pos` row, `+` for domain extents and `?` for the
  rest. `ddrescue -m` treats the `+` blocks as the domain. The round trip goes
  through the shipped `DdrescueMapfile` parser.

## Consequences

- **Fixtures.** `Tests/Fixtures/ntfs-disk-*` are the few KiB the parser needs
  (both boot sectors, `$MFT` records 0 and 6, `$Bitmap`, the raw
  `ntfscluster` output and the coalesced used-run list), recorded from the
  gitignored `captures/ntfs-spike/img`. `ntfs-disk-notes.md` records the
  ntfsinfo/ntfscluster readings and the commands. On the spike image the tools
  report 16383 clusters, 4075 free and 12308 used; the bitmap yields the same
  10 runs (0-2, 4-3710, … 16266-16382). Fixture and expectation move together.
- **Live tests are skippable, the pure tests are not.** One test writes an
  8 MiB source and an 8 MiB domain mapfile and runs real `ddrescue -m`, then
  asserts the domain bytes match and the gaps are zero. Two more read the real
  `disk.img` and compare the bitmap's runs with the recorded `ntfscluster`
  output and check every file data run is covered by the domain. When
  ddrescue or the capture is absent the test is `<skipped>`, which the gate
  answers as **3**, never a pass; the pure tests in
  `DiskTriageCoreTests.NTFSAllocationTests` always run.
- **Mutation checks.** (a) not restoring the USA tails, (b) backup offset
  `-1024`, (c) unsigned run offsets, (d) MSB-first bitmap bits, (e) counting
  the tail bit past the volume, and (f) treating an unread bitmap as all-free
  each turned the named test red; restoring each turned it green.
- **Judgement calls and plan gaps.** `$ATTRIBUTE_LIST` is unsupported by
  design (record 0/6 here have none); following extension records is a later
  feature. A sparse `$MFT` run contributes no physical extent. The stage-0 MFT
  region assumes records 0-15 start inside the first `$MFT` run (true at the
  spike's LCN 4, 31-cluster run); a fragmented `$MFT` whose first run is
  shorter needs the run map from record 0 first. The run-list cap is 65,536
  runs. 4Kn sectors are parsed but untested (the plan already leaves 4Kn
  unverified). No change is made to `diskdoctor.md`; the above are findings.

## Requirements

- REQ-0187
- REQ-0189
- REQ-0190
- REQ-0191
- REQ-0192
- REQ-0193
