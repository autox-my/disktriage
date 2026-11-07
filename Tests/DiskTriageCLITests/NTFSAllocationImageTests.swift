import Foundation
import Testing
import DiskTriageTestSupport
import DiskTriageCore
import DiskTriageCollectors
@testable import DiskTriageCLI

/// The allocation-aware NTFS order in `disktriage image` (diskdoctor.md §8,
/// "Allocation-aware order for NTFS (default)"), driven end-to-end through the
/// injected ddrescue launcher. The "device" is a copy of the synthetic
/// whole-disk NTFS image in `captures/ntfs-spike/img/disk.img`; the fake
/// launcher copies exactly the domain mapfile's `+` extents from that source
/// into the image, as ddrescue `-m` does, and rewrites the main mapfile.
///
/// Every test is `<skipped>` when the gitignored capture is absent, never a
/// pass. The pure expectations come from `Tests/Fixtures/ntfs-disk-*`.
struct NTFSAllocationImageTests {

    // MARK: - Default staging

    // REQ-0200
    @Test(
        "REQ0200 the default order is stage 0 metadata, stage 1 used clusters, stage 2 the rest",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0200_defaultStagingOrder() throws {
        let harness = try NTFSImageHarness()
        let result = harness.run()

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        let launches = harness.launcher.launches
        #expect(!launches.isEmpty)

        let stages = launches.map(\.stage)
        #expect(stages == stages.sorted(), "stages run in order: \(stages)")
        #expect(stages.contains(0) && stages.contains(1) && stages.contains(2))

        // Stage 1's domain is exactly the library's used domain.
        let expected = try fixtureDomain().used
        let stageOne = try #require(launches.first { $0.stage == 1 && $0.pass == .pass1 })
        #expect(stageOne.domain == expected,
                "stage 1 -m domain is the library's used domain")
        #expect(stageOne.domain.reduce(0) { $0 + $1.size } == 50_413_568)

        // Stage 2's domain is the whole-device complement of stage 1.
        let stageTwo = try #require(launches.first { $0.stage == 2 && $0.pass == .pass1 })
        #expect(stageTwo.domain.reduce(0) { $0 + $1.size } == harness.deviceSize - 50_413_568)
        #expect(result.stdout.contains("SCOPE"), "the scope is stated")
        #expect(result.stdout.contains("whole device"))
    }

    // REQ-0201
    @Test(
        "REQ0201 stage 0 reads partition table, boot sectors, MFT and bitmap through one main mapfile",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0201_stageZeroReadsMetadataBeforeUsedClusters() throws {
        let harness = try NTFSImageHarness()
        let result = harness.run()
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let stageZero = harness.launcher.launches.filter { $0.stage == 0 }
        #expect(stageZero.count >= 4, "partition table, boot sectors, MFT, bitmap")
        #expect(stageZero.allSatisfy { $0.domainPath?.hasSuffix(".domain-stage0.mapfile") == true },
                "stage 0 uses its domain mapfile")
        #expect(stageZero.allSatisfy { $0.mapfile == harness.mapfile },
                "everything lands in the same main mapfile")
        #expect(stageZero.allSatisfy { $0.pass == .metadata }, "no -n/-r3 in stage 0")

        // The metadata the parser read is rescued in the main mapfile before
        // stage 1 starts.
        let snapshot = try #require(DdrescueMapfile.parse(
            try String(contentsOfFile: harness.mapfile, encoding: .utf8)
        ))
        #expect(snapshot.extents.contains { $0.status == "+" && $0.position == 0 && $0.size >= 512 },
                "the partition table is rescued")

        let stageOneIndex = try #require(harness.launcher.launches.firstIndex { $0.stage == 1 })
        let mapfileBeforeStageOne = harness.launcher.mapfilesSeen[stageOneIndex]
        let before = try #require(DdrescueMapfile.parse(mapfileBeforeStageOne ?? ""))
        #expect(before.extents.contains {
            $0.status == "+" && $0.position <= 1_048_576 && $0.end > 1_048_576
        }, "the boot sector the MFT parse used is already rescued")
    }

    // REQ-0202
    @Test(
        "REQ0202 an invalid primary boot sector uses the backup and reports that source",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0202_backupBootSectorSuppliesGeometry() throws {
        let harness = try NTFSImageHarness()
        // The primary boot sector is the first sector of the partition.
        harness.zeroSourceRange(position: 1_048_576, length: 512)
        let result = harness.run(extra: ["--json"])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let allocation = try #require(object["allocation"] as? [String: Any])
        #expect(allocation["geometry_source"] as? String == "backup")

        // The used clusters still match the library's domain.
        let expected = try fixtureDomain().used
        let stageOne = try #require(harness.launcher.launches.first {
            $0.stage == 1 && $0.pass == .pass1
        })
        #expect(stageOne.domain == expected, "the backup geometry yields the same domain")
    }

    // MARK: - Fallback

    // REQ-0203
    @Test(
        "REQ0203 a non-NTFS source falls back to plain whole-device passes with a reason",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0203_nonNTFSFallsBack() throws {
        let harness = try NTFSImageHarness(sourceBytes: Data(repeating: 0x41, count: 4 * 1_048_576))
        let result = harness.run()

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(harness.launcher.launches.filter { $0.stage == 1 || $0.stage == 2 }.isEmpty,
                "no used/free domain is invented")
        #expect(harness.launcher.launches.filter { $0.stage == 0 }.count >= 1)
        #expect(harness.launcher.launches.contains { $0.domainPath == nil && $0.pass == .pass1 },
                "the plain pass 1 ran")
        #expect(harness.launcher.launches.contains { $0.domainPath == nil && $0.pass == .pass2 },
                "the plain pass 2 ran")
        #expect(result.stdout.contains("SCOPE"), "\(result.stdout)")
        #expect(result.stdout.contains("allocation unknown"))
        #expect(result.stdout.contains("NTFS") || result.stdout.contains("partition table"),
                "the reason is named")
        #expect(harness.imageEqualsSource(), "the fallback still read the whole device")
    }

    // REQ-0203 / REQ-0210
    @Test(
        "REQ0203_REQ0210 a zeroed $Bitmap falls back and never skips free space",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0203_REQ0210_zeroedBitmapFallsBackAndSkipsNothing() throws {
        let harness = try NTFSImageHarness()
        // The $Bitmap data run is LCN 2055, one cluster (recorded fixture).
        let clusterSize: Int64 = 4096
        let partitionOffset: Int64 = 1_048_576
        harness.zeroSourceRange(
            position: partitionOffset + 2055 * clusterSize,
            length: 4096
        )

        let result = harness.run(extra: ["--used-only"])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(harness.launcher.launches.filter { $0.stage == 1 || $0.stage == 2 }.isEmpty,
                "a zeroed bitmap is not an all-free allocation")
        #expect(result.stdout.contains("allocation unknown"), "\(result.stdout)")
        #expect(result.stdout.contains("whole device"))
        #expect(!result.stdout.contains("free space NOT imaged"),
                "free space must not be skipped after a failed bitmap parse")
        #expect(harness.imageEqualsSource(), "the fallback read even the free space")
    }

    // MARK: - --used-only

    // REQ-0204
    @Test(
        "REQ0204 --used-only stops after stage 1, says so, and exits 0",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0204_usedOnlySkipsStageTwo() throws {
        let harness = try NTFSImageHarness()
        let result = harness.run(extra: ["--used-only", "--json"])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(harness.launcher.launches.filter { $0.stage == 2 }.isEmpty,
                "stage 2 never runs")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["scope"] as? String == "used clusters + metadata (free space NOT imaged: --used-only)")
        #expect((object["allocation"] as? [String: Any])?["stage2"] as? String == "skipped")
        #expect(object["status"] as? String != "complete", "not a complete image of the device")
        #expect((object["status"] as? String)?.contains("used-only image complete") == true)
    }

    // REQ-0205
    @Test(
        "REQ0205 each stage runs -n then -r3, and -a is only in pass 1",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0205_eachStageRunsTwoPassesWithMinRateInPassOne() throws {
        let harness = try NTFSImageHarness()
        let result = harness.run()
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        for stage in [1, 2] {
            let launches = harness.launcher.launches.filter { $0.stage == stage }
            #expect(launches.map(\.pass) == [.pass1, .pass2], "stage \(stage): one of each")
            let passOne = try #require(launches.first { $0.pass == .pass1 })
            let passTwo = try #require(launches.first { $0.pass == .pass2 })
            #expect(passOne.argv.contains("-n"))
            #expect(passTwo.argv.contains("-r3"))
            #expect(value(after: "-a", in: passOne.argv) == "10000000",
                    "stage \(stage) pass 1 defers slow zones")
            #expect(!passTwo.argv.contains("-a"),
                    "stage \(stage) pass 2 must come back to the deferred zones")
        }
        #expect(harness.launcher.launches.filter { $0.stage == 0 }
            .allSatisfy { !$0.argv.contains("-a") }, "stage 0 metadata does not defer")
    }

    // REQ-0206
    @Test(
        "REQ0206 every stage domain is clipped to --limit",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0206_domainsAreClippedToTheLimit() throws {
        let harness = try NTFSImageHarness()
        let limit: Int64 = 10 * 1_048_576 // includes the bitmap at 9.47 MiB
        let result = harness.run(limitBytes: limit)

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        for launch in harness.launcher.launches where launch.stage == 1 || launch.stage == 2 {
            #expect(launch.domain.allSatisfy { $0.end <= limit },
                    "stage \(launch.stage) stays inside the limit: \(launch.domain)")
        }
        let stageOne = try #require(harness.launcher.launches.first {
            $0.stage == 1 && $0.pass == .pass1
        })
        let expected = try fixtureDomain().used.compactMap { extent -> ByteRange? in
            let end = min(extent.end, limit)
            guard end > extent.position else { return nil }
            return ByteRange(position: extent.position, size: end - extent.position)
        }
        #expect(stageOne.domain == expected, "used domain clipped, not truncated")
        #expect(stageOne.domain.reduce(0) { $0 + $1.size } < 50_413_568)
    }

    // MARK: - Sidecar and resume

    // REQ-0207 / REQ-0216
    @Test(
        "REQ0207_REQ0216 the sidecar records every stage and --used-only is not resume identity",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0207_REQ0216_sidecarRecordsStageStateAndUsedOnlyIsNotIdentity() throws {
        let harness = try NTFSImageHarness()
        let result = harness.run(extra: ["--used-only"])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let sidecar = try decodeSidecar(harness.image + ".disktriage.json")
        let allocation = try #require(sidecar.allocation)
        #expect(allocation.usedOnly == true)
        #expect(allocation.mode == "allocation-aware")
        #expect(allocation.stage0 == "done")
        #expect(allocation.geometrySource == "primary")
        #expect(allocation.stage1 == "done")
        #expect(allocation.stage2 == "skipped")

        // The opposite --used-only value is allowed on a dry run over the same
        // image; the limit is still the resume authority.
        let facts = DiskDestinationProbe().probe(
            destination: harness.image,
            mapfile: harness.mapfile
        )
        let sidecarFromFacts = try #require(facts.sidecar)
        #expect(sidecarMatchesDevice(
            sidecarFromFacts,
            model: "Synthetic Bridge Disk",
            serialHash: "140a7381765287afbe4ee54904e08feabe9024b26a0a769284e63f5a81ee1b57",
            sizeBytes: harness.deviceSize
        ) == true, "--used-only is not part of the identity")
    }

    // REQ-0211
    @Test(
        "REQ0211 a resume after an interruption at each stage continues at that stage",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0211_resumeContinuesAfterAnInterruptedStage() throws {
        for interruptedStage in [0, 1, 2] {
            let harness = try NTFSImageHarness()
            harness.launcher.shouldInterrupt = { launch in
                launch.stage == interruptedStage
                    && (interruptedStage == 0 || launch.pass == .pass2)
            }
            let first = harness.run()
            #expect(first.exitCode == 1, "stage \(interruptedStage) is incomplete and resumable")
            #expect(first.stdout.contains("RESUME"))

            let sidecarAfter = try decodeSidecar(harness.image + ".disktriage.json")
            let allocation = try #require(sidecarAfter.allocation)
            #expect(allocation.stage0 != "not-started")

            // Resume with a normal launcher and the real sidecar as authority.
            harness.launcher.shouldInterrupt = { _ in false }
            harness.launcher.reset()
            let resumed = harness.run()
            #expect(resumed.exitCode == 0, "stage \(interruptedStage): \(resumed.stdout)\n\(resumed.stderr)")
            #expect(resumed.stdout.contains("SCOPE"))

            switch interruptedStage {
            case 0:
                #expect(harness.launcher.launches.contains { $0.stage == 1 },
                        "stage 0 redone, then used clusters")
            case 1:
                let stageOne = harness.launcher.launches.filter { $0.stage == 1 }
                #expect(stageOne.map(\.pass) == [.pass2],
                        "stage 1 resumes at pass 2, not the completed pass 1")
            case 2:
                #expect(!harness.launcher.launches.contains { $0.stage == 1 },
                        "a completed stage 1 is not redone")
                #expect(harness.launcher.launches.contains {
                    $0.stage == 2 && $0.pass == .pass2
                }, "stage 2 resumes at pass 2")
            default:
                break
            }
            #expect(harness.imageEqualsSource(), "the resumed image is whole")
        }
    }

    // MARK: - Reporting

    // REQ-0208 / REQ-0217
    @Test(
        "REQ0208_REQ0217 the summary names the scope and never calls a used-only image complete",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0208_REQ0217_summaryScopeNeverClaimsAWholeDevice() throws {
        let harness = try NTFSImageHarness()
        let usedOnly = harness.run(extra: ["--used-only"])
        #expect(usedOnly.exitCode == 0)
        #expect(usedOnly.stdout.contains(
            "used clusters + metadata (free space NOT imaged: --used-only)"
        ), "\(usedOnly.stdout)")
        #expect(usedOnly.stdout.contains("used-only image complete"))
        #expect(!usedOnly.stdout.contains("complete image of the device"))
        #expect(usedOnly.stdout.contains("STAGE 0"))
        #expect(usedOnly.stdout.contains("STAGE 1"))
        #expect(usedOnly.stdout.contains("STAGE 2"))
        #expect(usedOnly.stdout.contains("skipped"))

        let whole = try NTFSImageHarness().run()
        #expect(whole.stdout.contains("whole device"))
        #expect(!whole.stdout.contains("free space NOT imaged"))
    }

    // REQ-0212
    @Test("REQ0212 progress is a percentage of the stage scope, not the whole device")
    func REQ0212_progressPercentIsOfTheStageScope() throws {
        let snapshot = try #require(DdrescueMapfile.parse("""
        # Mapfile. Created by GNU ddrescue version 1.30
        # current_pos  current_status  current_pass
        0x00000000     +              1
        #      pos        size  status
        0x00000000  0x00000400  +
        0x00000400  0x00000400  *
        0x00000800  0x00003800  ?
        """))
        let scope = [ByteRange(position: 0, size: 4096)]
        let accounting = scopeAccounting(snapshot: snapshot, scope: scope)
        #expect(accounting.totalBytes == 4096)
        #expect(accounting.rescuedBytes == 1024)
        #expect(accounting.failedBytes == 1024)
        #expect(accounting.remainingBytes == 3072,
                "the failed 1 KiB and the untried 2 KiB are both still to try")
        #expect(abs(accounting.rescuedFraction - 0.25) < 0.0001)

        let other = scopeAccounting(
            snapshot: snapshot,
            scope: [ByteRange(position: 1024, size: 2048)]
        )
        #expect(other.totalBytes == 2048)
        #expect(other.rescuedBytes == 0)
        #expect(other.failedBytes == 1024)
        #expect(other.remainingBytes == 2048)
    }

    // MARK: - Dry run

    // REQ-0209
    @Test("REQ0209 the dry run prints the stage 0..2 commands before any read")
    func REQ0209_dryRunPrintsTheStageCommands() {
        let result = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-serial", "ABCD"],
            executor: stageDryRunExecutor(),
            destinationProbe: FakeImageProbe(facts: DestinationFacts(
                destinationExists: false,
                mapfileExists: false,
                freeBytes: 2_000_000_000_000,
                containerFilesystem: "apfs",
                parentIsWritable: true,
                backingWholeDisk: "disk0"
            ))
        )

        #expect(result.exitCode == 0)
        for stage in 0...2 {
            #expect(result.stdout.contains("STAGE \(stage)"), "stage \(stage) is planned")
            #expect(result.stdout.contains(".domain-stage\(stage).mapfile"))
        }
        #expect(result.stdout.contains("domain computed from the bitmap"),
                "stage 1/2 say where the domain comes from")
        #expect(result.stdout.contains("FALLBACK"))
        #expect(result.stdout.contains("ddrescue -n -b 512"))
        #expect(result.stdout.contains("ddrescue -r3 -b 512"))

        let usedOnly = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img",
                        "--confirm-serial", "ABCD", "--used-only"],
            executor: stageDryRunExecutor(),
            destinationProbe: FakeImageProbe(facts: DestinationFacts(
                destinationExists: false,
                mapfileExists: false,
                freeBytes: 2_000_000_000_000,
                containerFilesystem: "apfs",
                parentIsWritable: true,
                backingWholeDisk: "disk0"
            ))
        )
        #expect(usedOnly.exitCode == 0)
        #expect(usedOnly.stdout.contains("skipped by --used-only"))
    }

    // MARK: - Helpers

    private func stageDryRunExecutor() -> CLIExecutor {
        let text = (try? String(contentsOfFile: fixturePath(
            "diskutil-info-usb-synthetic-serial.plist"
        ), encoding: .utf8)) ?? ""
        return CLIExecutor { command in
            switch command {
            case .diskutilInfo:
                return .ok(text)
            case .ioregStatistics:
                return .ok((try? String(contentsOfFile: fixturePath(
                    "ioreg-internal-driver.txt"
                ), encoding: .utf8)) ?? "")
            case .ioregMedia:
                return .ok((try? String(contentsOfFile: fixturePath(
                    "ioreg-iomedia-internal.txt"
                ), encoding: .utf8)) ?? "")
            case .logShow:
                return .ok("")
            case .smartctl:
                return .ok(#"{"smartctl":{"exit_status":0}}"#)
            default:
                return .ok("")
            }
        }
    }
}

// MARK: - The harness

/// A copy of the synthetic whole-disk NTFS image as the "device", the fake
/// launcher that copies its domain, and the real file seams.
private final class NTFSImageHarness {
    private let temp = TempDir()
    let directory: String
    let source: String
    let image: String
    let mapfile: String
    let deviceSize: Int64
    let launcher: StageFakeDdrescueLauncher

    init(sourceBytes: Data? = nil) throws {
        let capture = try #require(ntfsDiskImagePath(), "captures/ntfs-spike/img/disk.img")
        directory = temp.path
        source = directory + "/device.bin"
        image = directory + "/disk.img"
        mapfile = image + ".mapfile"
        let bytes = try sourceBytes ?? Data(contentsOf: URL(fileURLWithPath: capture))
        try bytes.write(to: URL(fileURLWithPath: source))
        deviceSize = Int64(bytes.count)
        launcher = StageFakeDdrescueLauncher(source: source, deviceSize: deviceSize)
    }

    func zeroSourceRange(position: Int64, length: Int) {
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: source))
        defer { try? handle?.close() }
        try? handle?.seek(toOffset: UInt64(position))
        try? handle?.write(contentsOf: Data(repeating: 0, count: length))
    }

    func run(extra: [String] = [], limitBytes: Int64? = nil) -> CLIResult {
        let dependencies = ImagingDependencies(
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            allocationAware: true,
            readImage: readImageFile
        )
        return DiskTriageCLI.image(
            ["disk8", "--to", image, "--no-dry-run", "--accept-risk",
             "--confirm-serial", "ABCD"] + extra,
            executor: imagingExecutor(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            destinationProbe: DiskDestinationProbe(),
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: dependencies,
            limitBytesOverride: limitBytes,
            deviceSizeOverride: deviceSize
        )
    }

    func imageEqualsSource() -> Bool {
        guard let sourceData = try? Data(contentsOf: URL(fileURLWithPath: source)),
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: image))
        else { return false }
        return sourceData == imageData
    }
}

func readImageFile(_ path: String, _ offset: Int64, _ length: Int) -> Data? {
    guard offset >= 0, length >= 0,
          let handle = FileHandle(forReadingAtPath: path)
    else { return nil }
    defer { try? handle.close() }
    do {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    } catch {
        return nil
    }
}

// MARK: - The fake ddrescue

final class StageFakeDdrescueLauncher: DdrescueLaunching, @unchecked Sendable {
    enum PassKind: String {
        case metadata
        case pass1
        case pass2
    }

    struct Launch {
        let argv: [String]
        let stage: Int
        let pass: PassKind
        let domainPath: String?
        let domain: [ByteRange]
        let image: String
        let mapfile: String
    }

    let source: String
    let deviceSize: Int64
    private(set) var launches: [Launch] = []
    /// The main mapfile's text as it stood when each launch started.
    private(set) var mapfilesSeen: [String?] = []
    var shouldInterrupt: (Launch) -> Bool = { _ in false }

    func reset() {
        launches.removeAll()
        mapfilesSeen.removeAll()
    }

    init(source: String, deviceSize: Int64) {
        self.source = source
        self.deviceSize = deviceSize
    }

    func launch(argv: [String]) throws -> any DdrescueProcessHandle {
        let image = argv[argv.count - 2]
        let mapfile = argv[argv.count - 1]
        let domainPath = value(after: "-m", in: argv)
        let domain = domainPath.flatMap(readDomain) ?? wholeDomain(argv: argv)
        let stage = stage(of: domainPath)
        let pass: PassKind = argv.contains("-n") ? .pass1
            : argv.contains("-r3") ? .pass2 : .metadata
        let launch = Launch(
            argv: argv,
            stage: stage,
            pass: pass,
            domainPath: domainPath,
            domain: domain,
            image: image,
            mapfile: mapfile
        )
        launches.append(launch)
        mapfilesSeen.append(try? String(contentsOfFile: mapfile, encoding: .utf8))
        if shouldInterrupt(launch) {
            return InterruptingProcess()
        }
        try copy(domain: domain, to: image)
        try updateMapfile(mapfile, adding: domain)
        return ImmediateProcess()
    }

    private func stage(of path: String?) -> Int {
        // No `-m` is a plain whole-device fallback pass, not allocation stage 2.
        guard let path else { return 0 }
        for stage in 0...2 where path.contains("domain-stage\(stage)") { return stage }
        return 0
    }

    /// A plain run (no `-m`) reads the whole device, bounded by `-s` when given.
    private func wholeDomain(argv: [String]) -> [ByteRange] {
        let size = Int64(value(after: "-s", in: argv) ?? "") ?? deviceSize
        return [ByteRange(position: 0, size: min(size, deviceSize))]
    }

    private func readDomain(_ path: String) -> [ByteRange]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let snapshot = DdrescueMapfile.parse(text)
        else { return nil }
        return snapshot.extents.filter { $0.status == "+" }.map {
            ByteRange(position: $0.position, size: $0.size)
        }
    }

    private func copy(domain: [ByteRange], to image: String) throws {
        if !FileManager.default.fileExists(atPath: image) {
            FileManager.default.createFile(atPath: image, contents: Data())
        }
        guard let input = FileHandle(forReadingAtPath: source),
              let output = FileHandle(forWritingAtPath: image)
        else { throw CocoaError(.fileReadUnknown) }
        defer {
            try? input.close()
            try? output.close()
        }
        for extent in domain {
            guard extent.position < deviceSize, extent.size > 0 else { continue }
            let length = Int(min(extent.size, deviceSize - extent.position))
            try input.seek(toOffset: UInt64(extent.position))
            let bytes = try input.read(upToCount: length) ?? Data()
            try output.seek(toOffset: UInt64(extent.position))
            try output.write(contentsOf: bytes)
        }
    }

    private func updateMapfile(_ path: String, adding extents: [ByteRange]) throws {
        var rescued = extents
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let existing = DdrescueMapfile.parse(text) {
            rescued += existing.extents.filter { $0.status == "+" }.map {
                ByteRange(position: $0.position, size: $0.size)
            }
        }
        let merged = merge(rescued)
        var text = "# Mapfile. Created by GNU ddrescue version 1.30\n"
            + "# current_pos  current_status  current_pass\n0x00000000  ?  1\n"
            + "#      pos        size  status\n"
        var cursor: Int64 = 0
        for extent in merged {
            if extent.position > cursor {
                text += row(cursor, extent.position - cursor, "?")
            }
            text += row(extent.position, extent.size, "+")
            cursor = extent.end
        }
        if deviceSize > cursor {
            text += row(cursor, deviceSize - cursor, "?")
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

private final class ImmediateProcess: DdrescueProcessHandle, @unchecked Sendable {
    let pid: Int32 = 4242
    func poll() -> Int32? { 0 }
    func signal(_ signal: Int32) {}
}

private final class InterruptingProcess: DdrescueProcessHandle, @unchecked Sendable {
    let pid: Int32 = 4243
    private var done = false
    func poll() -> Int32? {
        if done { return 130 }
        done = true
        return 130
    }
    func signal(_ signal: Int32) {}
}

// MARK: - Pure helpers under test

func merge(_ extents: [ByteRange]) -> [ByteRange] {
    let sorted = extents.filter { $0.size > 0 }.sorted {
        $0.position == $1.position ? $0.size < $1.size : $0.position < $1.position
    }
    var merged: [ByteRange] = []
    for extent in sorted {
        if let last = merged.last, extent.position <= last.end {
            let end = max(last.end, extent.end)
            merged[merged.count - 1] = ByteRange(position: last.position, size: end - last.position)
        } else {
            merged.append(extent)
        }
    }
    return merged
}

private func row(_ position: Int64, _ size: Int64, _ status: String) -> String {
    String(format: "0x%08llX  0x%08llX  %@\n", position, size, status)
}

func value(after flag: String, in argv: [String]) -> String? {
    guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
    return argv[index + 1]
}

// MARK: - The recorded fixtures

func fixtureDomain() throws -> NTFSAllocationDomain {
    let geometry = try NTFSBootGeometry.parse(fixtureDataFile("ntfs-disk-boot-primary.bin")).get()
    let outcome = NTFSAllocation.evaluate(
        geometry: geometry,
        mftRecord: try fixtureDataFile("ntfs-disk-mft-record-0.bin"),
        bitmapRecord: try fixtureDataFile("ntfs-disk-mft-record-6.bin"),
        bitmapData: try fixtureDataFile("ntfs-disk-bitmap.bin"),
        partitionOffset: 1_048_576,
        partitionLength: 67_108_864
    )
    return try #require(outcome.domain, "fixture allocation: \(outcome)")
}

private func fixtureDataFile(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: fixturePath(name)))
}

// MARK: - Availability

func ntfsDiskImagePath() -> String? {
    for root in candidateRepositoryRoots() {
        let path = root + "/captures/ntfs-spike/img/disk.img"
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    return nil
}

func imagingExecutor() -> CLIExecutor {
    let text = (try? String(contentsOfFile: fixturePath(
        "diskutil-info-usb-synthetic-serial.plist"
    ), encoding: .utf8)) ?? ""
    return CLIExecutor { command in
        switch command {
        case .diskutilInfo:
            return .ok(text)
        case .ioregStatistics:
            return .ok((try? String(contentsOfFile: fixturePath(
                "ioreg-internal-driver.txt"
            ), encoding: .utf8)) ?? "")
        case .ioregMedia:
            return .ok((try? String(contentsOfFile: fixturePath(
                "ioreg-iomedia-internal.txt"
            ), encoding: .utf8)) ?? "")
        case .logShow:
            return .ok("")
        case .smartctl:
            return .ok(#"{"smartctl":{"exit_status":0}}"#)
        default:
            return .ok("")
        }
    }
}
