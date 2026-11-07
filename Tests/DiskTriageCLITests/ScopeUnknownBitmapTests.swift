import Foundation
import Testing
import DiskTriageTestSupport
import DiskTriageCore
import DiskTriageCollectors
@testable import DiskTriageCLI

/// The `$Bitmap` trust rule in stage 0 (diskdoctor.md §8, "Allocation-aware
/// order for NTFS"): a bitmap byte the main mapfile did not finish is UNKNOWN
/// allocation, never free. The real expectations come from
/// `Tests/Fixtures/minah-scope-mapfile.txt` (redacted, with the arithmetic in
/// `minah-scope-notes.md`); the synthetic end-to-end runs use
/// `captures/ntfs-spike/img/disk.img`, whose bitmap data is the recorded
/// `$Bitmap` at LCN 2055 (one 4096-byte cluster, 2048 bytes of data).
struct ScopeUnknownBitmapTests {

    // MARK: - The real MiNaH mapfile

    // REQ-0238
    @Test("REQ0238 the real MiNaH mapfile hides exactly 4096 bitmap bytes and 32768 clusters")
    func REQ0238_realMiNaHMapfileYieldsTheRecordedUnknowns() throws {
        let text = try String(
            contentsOfFile: fixturePath("minah-scope-mapfile.txt"),
            encoding: .utf8
        )
        let snapshot = try #require(DdrescueMapfile.parse(text))
        let unfinished = snapshot.extents
            .filter { $0.status != "+" && $0.size > 0 }
            .map { ByteRange(position: $0.position, size: $0.size) }

        // The stage-0 domain extent for the $Bitmap data, from the same run.
        let trust = NTFSBitmapTrust.unreadable(
            bitmapRuns: [ByteRange(position: 0x2542_E8A000, size: 0x951000)],
            unfinished: unfinished,
            clusterBytes: 4_096,
            totalClusters: 78_142_207
        )

        #expect(trust.bitmapBytes == 4_096, "the three rows total 0x600 + 0x800 + 0x200")
        #expect(trust.extentCount == 1, "the three rows are adjacent bitmap bytes")
        #expect(trust.byteRanges == [ByteRange(position: 4_681_728, size: 4_096)])
        #expect(trust.clusterCount == 32_768, "4096 bytes x 8 clusters per bit")
        #expect(trust.unknownBytes == 134_217_728, "32,768 x 4096-byte clusters")
        #expect(trust.clusters == [
            try #require(ClusterRange(first: 37_453_824, last: 37_486_591)),
        ])
    }

    // MARK: - End to end: unknown clusters are stage-1 used, never free

    // REQ-0239 / REQ-0240
    @Test(
        "REQ0239_REQ0240 unknown bitmap clusters are read in stage 1 and never in stage 2",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0239_REQ0240_unknownBitmapClustersAreStageOneNotStageTwo() throws {
        let harness = try UnknownBitmapHarness()
        let damage = harness.damageBitmapData(offset: 475, length: 16)
        let result = harness.run(bad: [damage])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        // Bitmap bytes 475..<491 cover clusters 3800..<3928, bitmap-free on the
        // spike (free run 3711-4200).
        let unknown = ByteRange(position: 1_048_576 + 3_800 * 4_096, size: 128 * 4_096)

        let stageOne = try #require(harness.launcher.launches.first {
            $0.stage == 1 && $0.pass == .pass1
        })
        #expect(stageOne.domain.contains {
            $0.position <= unknown.position && $0.end >= unknown.end
        }, "stage 1 reads the unknown clusters: \(stageOne.domain)")

        let stageTwo = try #require(harness.launcher.launches.first {
            $0.stage == 2 && $0.pass == .pass1
        })
        #expect(!stageTwo.domain.contains {
            $0.position < unknown.end && unknown.position < $0.end
        }, "the stage-2 complement excludes them: \(stageTwo.domain)")
    }

    // REQ-0240 / REQ-0241
    @Test(
        "REQ0241 --used-only images the unknown clusters and the report counts them separately",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0241_usedOnlyImagesUnknownClustersAndTheReportIsSeparate() throws {
        let harness = try UnknownBitmapHarness()
        let damage = harness.damageBitmapData(offset: 475, length: 16)
        let result = harness.run(extra: ["--used-only", "--json"], bad: [damage])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(harness.launcher.launches.filter { $0.stage == 2 }.isEmpty,
                "a --used-only run never starts stage 2")

        let unknown = ByteRange(position: 1_048_576 + 3_800 * 4_096, size: 128 * 4_096)
        let stageOne = try #require(harness.launcher.launches.first {
            $0.stage == 1 && $0.pass == .pass1
        })
        #expect(stageOne.domain.contains {
            $0.position <= unknown.position && $0.end >= unknown.end
        }, "--used-only still images the unknown clusters")
    }

    // REQ-0241
    @Test(
        "REQ0241 the scope report keeps used/free and reports unknown beside them",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0241_scopeReportSeparatesUsedFreeAndUnknown() throws {
        let harness = try UnknownBitmapHarness()
        let damage = harness.damageBitmapData(offset: 475, length: 16)
        let result = harness.run(extra: ["--json"], scopeReport: true, bad: [damage])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let report = try unknownScopeReport(result.stdout)
        #expect(report["used_clusters"] as? Int == 12_308, "used stays the bitmap's count")
        #expect(report["free_clusters"] as? Int == 3_947, "4075 trustworthy free minus 128")
        #expect(report["unknown_clusters"] as? Int == 128)
        #expect(report["unknown_bytes"] as? Int == 524_288)
        #expect(report["unknown_extents"] as? Int == 1)
        #expect(report["bitmap_unreadable_bytes"] as? Int == 16)
        #expect(report["stage1_clusters"] as? Int == 12_436, "used + unknown")
        #expect(report["stage1_bytes"] as? Int == 50_937_856)
        #expect(report["used_bytes"] as? Int == 50_413_568)
        #expect(report["free_bytes"] as? Int == 16_166_912)

        // The ETA is stage 1's bytes at the 30-37 MB/s assumption, not used only.
        let low = try #require(report["eta_low_seconds"] as? Double)
        let high = try #require(report["eta_high_seconds"] as? Double)
        #expect(abs(low - 50_937_856.0 / 37_000_000.0) < 0.001)
        #expect(abs(high - 50_937_856.0 / 30_000_000.0) < 0.001)

        // The human report is the same value rendered as lines.
        let human = try UnknownBitmapHarness()
        let humanDamage = human.damageBitmapData(offset: 475, length: 16)
        let humanText = human.run(scopeReport: true, bad: [humanDamage]).stdout
        #expect(humanText.contains("UNKNOWN"), "\(humanText)")
        #expect(humanText.contains("128 clusters"), "\(humanText)")
        #expect(humanText.contains("counted as used"), "\(humanText)")
        #expect(humanText.contains("stage-1 bytes"), "the NOTE names the ETA basis")
    }

    // MARK: - More than ten percent is not worth the staging

    // REQ-0242
    @Test(
        "REQ0242 more than ten percent unreadable $Bitmap falls back to whole-device passes",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0242_moreThanTenPercentUnreadableBitmapFallsBack() throws {
        let harness = try UnknownBitmapHarness()
        // 512 of the 2048 bitmap bytes is 25 percent.
        let damage = harness.damageBitmapData(offset: 475, length: 512)
        let result = harness.run(bad: [damage])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(harness.launcher.launches.filter { $0.stage == 1 || $0.stage == 2 }.isEmpty,
                "no allocation-aware stage is built from a mostly unreadable bitmap")
        #expect(harness.launcher.launches.contains { $0.domainPath == nil && $0.pass == .pass1 },
                "the plain pass 1 ran")
        #expect(result.stdout.contains("allocation unknown"), "\(result.stdout)")
        #expect(result.stdout.contains("10 percent"), "the reason names the threshold")
        #expect(harness.imageEqualsSource(), "the fallback read the whole device")
    }

    // MARK: - Boot sectors

    // REQ-0243
    @Test(
        "REQ0243 an unfinished primary boot sector is not used; the backup supplies the geometry",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0243_unfinishedPrimaryBootSectorFallsBackToTheBackup() throws {
        let harness = try UnknownBitmapHarness()
        let primary = ByteRange(position: 1_048_576, size: 512)
        let result = harness.run(extra: ["--json"], scopeReport: true, bad: [primary])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        let report = try unknownScopeReport(result.stdout)
        #expect(report["geometry_source"] as? String == "backup")
        #expect(report["used_clusters"] as? Int == 12_308)
    }

    // REQ-0243
    @Test(
        "REQ0243 when neither boot sector is finished the scope report fails and names it",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0243_unfinishedBothBootSectorsIsATypedFailure() throws {
        let harness = try UnknownBitmapHarness()
        let result = harness.run(
            scopeReport: true,
            bad: [
                ByteRange(position: 1_048_576, size: 512),
                ByteRange(position: 68_156_928, size: 512),
            ]
        )
        #expect(result.exitCode == 1, "\(result.stdout)\n\(result.stderr)")
        #expect(result.stderr.contains("boot sector"), "the structure is named: \(result.stderr)")
        #expect(result.stdout.isEmpty, "nothing is guessed")
    }

    // MARK: - MFT records

    // REQ-0244
    @Test(
        "REQ0244 an unfinished $MFT record 0 falls back to whole-device passes and names it",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0244_unfinishedMFTRecordZeroFallsBack() throws {
        let harness = try UnknownBitmapHarness()
        // Record 0 at $MFT LCN 4 (4096-byte clusters) after the partition start.
        let recordZero = ByteRange(position: 1_048_576 + 16_384, size: 1_024)
        let result = harness.run(bad: [recordZero])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(harness.launcher.launches.filter { $0.stage == 1 || $0.stage == 2 }.isEmpty,
                "no used/free domain is built from an untrusted record 0")
        #expect(harness.launcher.launches.contains { $0.domainPath == nil && $0.pass == .pass1 })
        #expect(result.stdout.contains("allocation unknown"), "\(result.stdout)")
        #expect(result.stdout.contains("$MFT record 0"), "the structure is named: \(result.stdout)")
    }

    // REQ-0244
    @Test(
        "REQ0244 an unfinished $Bitmap record 6 is a typed stage-0 failure",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0244_unfinishedBitmapRecordFails() throws {
        let harness = try UnknownBitmapHarness()
        // Record 6 is the seventh 1024-byte record at $MFT LCN 4.
        let recordSix = ByteRange(position: 1_048_576 + 16_384 + 6 * 1_024, size: 1_024)
        let result = harness.run(scopeReport: true, bad: [recordSix])
        #expect(result.exitCode == 1, "\(result.stdout)\n\(result.stderr)")
        #expect(result.stderr.contains("$Bitmap record 6"), "\(result.stderr)")
        #expect(result.stdout.isEmpty)
    }

    // REQ-0245
    @Test(
        "REQ0245 other unfinished MFT records are reported as unreadable, not fatal",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0245_otherUnfinishedMFTRecordsAreReported() throws {
        let harness = try UnknownBitmapHarness()
        let recordSeven = ByteRange(position: 1_048_576 + 16_384 + 7 * 1_024, size: 1_024)
        let result = harness.run(scopeReport: true, bad: [recordSeven])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(result.stdout.contains("unreadable metadata records: 1"), "\(result.stdout)")
    }

    // MARK: - JSON and the sidecar

    // REQ-0247
    @Test(
        "REQ0247 the JSON and the sidecar carry the unknown-bitmap keys",
        .enabled(if: ntfsDiskImagePath() != nil, "captures/ntfs-spike/img/disk.img not present")
    )
    func REQ0247_jsonAndSidecarCarryTheUnknownBitmapKeys() throws {
        let harness = try UnknownBitmapHarness()
        let damage = harness.damageBitmapData(offset: 475, length: 16)
        let result = harness.run(extra: ["--json"], scopeReport: true, bad: [damage])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let report = try unknownScopeReport(result.stdout)
        let sidecar = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: harness.image + ".disktriage.json"))
            ) as? [String: Any]
        )
        let recorded = try #require(sidecar["scope_report"] as? [String: Any])
        for key in [
            "unknown_clusters", "unknown_bytes", "unknown_extents",
            "bitmap_unreadable_bytes", "stage1_clusters", "stage1_bytes",
        ] {
            #expect(report[key] as? Int == recorded[key] as? Int, "\(key) in both")
        }
        #expect(recorded["unknown_clusters"] as? Int == 128)
        #expect(recorded["bitmap_unreadable_bytes"] as? Int == 16)
    }
}

// MARK: - The harness

/// A copy of the synthetic whole-disk NTFS image, the fake launcher, and a
/// damaged `$Bitmap` range the fake records as `-` in the main mapfile.
private final class UnknownBitmapHarness {
    static let bitmapDataOffset: Int64 = 1_048_576 + 2_055 * 4_096

    private let temp = TempDir()
    let directory: String
    let source: String
    let image: String
    let deviceSize: Int64
    let launcher: StageFakeDdrescueLauncher
    var mapfile: String { image + ".mapfile" }

    init() throws {
        let capture = try #require(ntfsDiskImagePath(), "captures/ntfs-spike/img/disk.img")
        directory = temp.path
        source = directory + "/device.bin"
        image = directory + "/disk.img"
        try Data(contentsOf: URL(fileURLWithPath: capture)).write(
            to: URL(fileURLWithPath: source)
        )
        deviceSize = Int64(
            (try FileManager.default.attributesOfItem(atPath: source)[.size] as? NSNumber)?
                .int64Value ?? 0
        )
        launcher = StageFakeDdrescueLauncher(source: source, deviceSize: deviceSize)
    }

    /// Zero-fills the bitmap bytes (as ddrescue would) and returns the device
    /// range to mark `-` in the main mapfile.
    func damageBitmapData(offset: Int64, length: Int) -> ByteRange {
        let position = Self.bitmapDataOffset + offset
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: source))
        defer { try? handle?.close() }
        try? handle?.seek(toOffset: UInt64(position))
        try? handle?.write(contentsOf: Data(repeating: 0, count: length))
        return ByteRange(position: position, size: Int64(length))
    }

    func run(
        extra: [String] = [],
        scopeReport: Bool = false,
        bad: [ByteRange] = []
    ) -> CLIResult {
        launcher.badRanges = { _ in bad }
        var arguments = ["disk8", "--to", image, "--no-dry-run",
                         "--accept-risk", "--confirm-serial", "ABCD"]
        if scopeReport { arguments.append("--scope-report") }
        arguments += extra
        let dependencies = ImagingDependencies(
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            allocationAware: true,
            readImage: readImageFile
        )
        return DiskTriageCLI.image(
            arguments,
            executor: imagingExecutor(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            destinationProbe: DiskDestinationProbe(),
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: dependencies,
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

private func unknownScopeReport(_ stdout: String) throws -> [String: Any] {
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
    )
    return try #require(object["scope_report"] as? [String: Any])
}
