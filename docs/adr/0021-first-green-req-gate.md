# 0021. First green `req gate` — dispositions for the 40 unlinked claims

Status: accepted
Date: 2026-11-07

## Context

`req gate --test-report .build/test-results/junit-swift-testing.xml` now exits
**0**: 33 claims were linked to a test that proves them, 6 were reworded to the
implemented obligation (and linked), and 1 is process-evidenced. No claim was
deleted.

## Decision

**Contract change (REQ-0097).** `FILESYSTEM` on an NTFS volume now prints the
plan's repair hand-off (`ntfsfix` / `chkdsk` against a copy, never in place) in
the tty detail and in `next.why`; the tool still performs no repair. The new
fields never appear for a non-NTFS filesystem, so the MiNaH transcript is
unchanged.

**Findings.** The plan's `diskutil unmountDisk` guard bullet (§8) is not
implemented: `guard` never writes and never unmounts, and `--suspend` prevents
probe and mount from the start. REQ-0073/REQ-0074 were reworded to that
implemented rule, with the old option recorded in
`rationale.rejected_alternatives`. Native read-only attach for
APFS/HFS+/exFAT/FAT is likewise not implemented (detected and refused), so
REQ-0088 was narrowed to the NTFS userspace path. REQ-0003 (no TCC prompt during
triage) is a platform property: it is `evidence: process`, citing
`docs/collectors-observations.md` §1 and `docs/p0-runbook.md` §3 row 7.

## Consequences

No claim was deleted. The dispositions are:

| Claim | Disposition | Reason | Linked test |
|---|---|---|---|
| REQ-0001 | a | no policy allows a mount shape | `DiskTriageCollectorsTests.CommandPolicyTests::REQ0001_REQ0005_REQ0006_REQ0073_noMountUnmountOrDriverLoadIsAllowed()` |
| REQ-0002 | a | a denied raw read still yields a verdict | `DiskTriageCoreTests.ClassifierTests::REQ-0002 REQ-0041 a denied permission is a status, not the verdict, when a verdict exists()` |
| REQ-0003 | c | TCC prompt suppression is a platform property, not testable | — |
| REQ-0005 | a | no mount/install shape is allow-listed | `…CommandPolicyTests::REQ0001_REQ0005_REQ0006_REQ0073_noMountUnmountOrDriverLoadIsAllowed()` |
| REQ-0006 | a | drivers listed; install shapes rejected | `…CheckRunnerTests::REQ0006_REQ0069_REQ0070_reportsEveryRowAndToolVersion()` |
| REQ-0007 | a | top cause carries evidence, falsifier, cheapest test | `…ClassifierTests::REQ-0007 the top hypothesis carries evidence, a falsifier and the cheapest test()` |
| REQ-0008 | a | no score or health field in either rendering | `…ClassifierTests::REQ-0008 REQ-0030 REQ-0100 a clean drive is … never a score()` |
| REQ-0009 | b | history snapshot is the one exception; linked to the read-only defaults | `…InspectCommandTests::REQ0009_REQ0010_REQ0088_REQ0113_bareInspectionIsReadOnly()` |
| REQ-0010 | b | the image mapfile/sidecar, `--record` and history are named writes | `…CopyCommandTests::REQ0009_REQ0010_REQ0129_imageIsNeverWritten()` |
| REQ-0016 | a | fixture-driven pure classification | `…ClassifierTests::REQ-0016 REQ-0025 MiNaH is MEDIA …` |
| REQ-0017 | a | key is the serial SHA-256; no serial means no key, never BSD | `…SnapshotStoreTests::REQ0017_REQ0156_keyIsTheFullSha256OfTheSerial()` |
| REQ-0019 | a | null history never fires the rising-reallocated rule | `…ClassifierTests::REQ-0018 REQ-0019 a null history never fires …` |
| REQ-0027 | a | weak/circumstantial evidence is low confidence | `…ClassifierTests::REQ-0027 REQ-0039 a low-confidence MEDIA …` |
| REQ-0042 | a | `triage --from` reads/writes no store; history is optional | `…HistoryCLITests::REQ0042_REQ0159_recordedSignalSetNeverTouchesTheStore()` |
| REQ-0055 | a | inspect refuses `/dev` and a symlink to it | `…InspectCommandTests::REQ0055_REQ0111_refusesADeviceNode()` |
| REQ-0056 | a | every command's `--json` path is exercised | `…CLITests::REQ-0056 REQ0057_REQ0058 --json prints …` (plus list/check/guard/image/inspect/copy) |
| REQ-0063 | a | 4096-byte internal read; no suspect fallback | `…RawDeviceProbeTests::REQ0063_probeAsksFor4096Bytes()` |
| REQ-0064 | a | EPERM is DENIED, EACCES is granted + sudo | `…FDAStateTests::REQ0064_EACCESMeansTCCPassedButUnixDenied()` |
| REQ-0065 | a | the full MiNaH transcript renders with `raw_read: denied` | `…CLITests::REQ-0065 REQ0057_REQ0058_REQ0059 triage --from …` |
| REQ-0066 | a | denied FDA blocks imaging with the reason | `…ImagingExecutionTests::REQ0043_REQ0066_deniedFDABlocks()` |
| REQ-0069 | a | root, raw, removable, log, guard and drivers rows present | `…CheckRunnerTests::REQ0006_REQ0069_REQ0070_reportsEveryRowAndToolVersion()` |
| REQ-0070 | a | smartctl/ddrescue rows carry versions | same test |
| REQ-0073 | b | guard prevents a mount and never unmounts (plan §8 unmount not implemented) | `…GuardDecisionTests::REQ0071_REQ0073_dissentsOnlyForExternalPhysicalDisks()` |
| REQ-0074 | b | suspend teardown prints the disconnect instruction; no unmount exists | `…GuardCommandTests::REQ0074_suspendHoldsWhenANewNodeAppeared()` |
| REQ-0075 | a | the shipped launcher really spawns a child | `…ImagingExecutionTests::REQ0075_shippedLauncherSpawnsARealProcess()` |
| REQ-0080 | a | `caffeinate` wraps both passes | `…ImagingRulesTests::REQ0080_REQ0083_REQ0086_twoPassesUseTheRawNodeAndNoDirectIO()` |
| REQ-0082 | a | an override image run issues no smartctl | `…ImagingExecutionTests::REQ0082_imagingNeverPollsSMART()` |
| REQ-0086 | a | `-O` and `-K 65536` in both passes | `…ImagingRulesTests::REQ0080_REQ0083_REQ0086_twoPassesUseTheRawNodeAndNoDirectIO()` |
| REQ-0088 | b | NTFS userspace read-only, no mount; native attach not implemented | `…InspectCommandTests::REQ0009_REQ0010_REQ0088_REQ0113_bareInspectionIsReadOnly()` |
| REQ-0089 | a | `ntfsfix`, `-f` and writer flags are rejected | `…NTFSToolsTests::REQ0089_REQ0098_REQ0114_rejectsEverythingElse()` |
| REQ-0090 | a | unreadable regions are a zero-filled damage note, exit 1 | `…InspectCommandTests::REQ0056_REQ0090_REQ0091_REQ0116_mapfileReportsDamage()` |
| REQ-0091 | a | inspect and copy both consult the mapfile | same inspect test + `…CopyCommandTests::REQ0091_REQ0093_REQ0128_REQ0134_REQ0136_copiesAndAttributes()` |
| REQ-0092 | b | scope is always volume; attribution `none` only when unavailable | `…CopyCommandTests::REQ0092_REQ0095_REQ0130_REQ0131_REQ0134_noMapfileMakesNoClaim()` |
| REQ-0093 | a | read and written SHA-256 per entry | `…CopyCommandTests::REQ0091_REQ0093_REQ0128_REQ0134_REQ0136_copiesAndAttributes()` |
| REQ-0094 | a | the manifest states hash equality is against the image | `…CopyCommandTests::REQ0094_REQ0132_hashEqualityWording()` |
| REQ-0095 | a | no per-file integrity claim without real extent mapping | `…CopyCommandTests::REQ0095_REQ0131_failedAttributionMakesNoClaim()` |
| REQ-0096 | a | FILESYSTEM prescription targets a copy | `…ClassifierTests::REQ-0096 the FILESYSTEM prescription targets a copy of the image()` |
| REQ-0097 | a | NTFS repair is printed as a hand-off, never performed | `…ClassifierTests::REQ-0097 an NTFS repair is a hand-off on a copy, never performed()` |
| REQ-0098 | a | `ntfsfix` is rejected before exec | `…NTFSToolsTests::REQ0089_REQ0098_REQ0114_rejectsEverythingElse()` |
| REQ-0100 | a | a clean verdict never says healthy, safe or scored | `…ClassifierTests::REQ-0008 REQ-0030 REQ-0100 a clean drive …` |

## Requirements

None. No claim's `rationale.source` points at this record; the dispositions
table names the claims it settled.
