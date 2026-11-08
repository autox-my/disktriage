import Foundation
import Darwin
import Testing
import DiskTriageTestSupport
import DiskTriageCore
import DiskTriageCollectors
@testable import DiskTriageCLI

/// `disktriage image <disk> --to <file> --scope-report` (diskdoctor.md §8,
/// "`--scope-report`"): stage 0 only, then the allocation. The "device" is a
/// copy of the synthetic whole-disk NTFS image `scripts/bootstrap.sh`
/// generates; the fake launcher copies exactly the domain mapfile's `+`
/// extents, as ddrescue `-m` does.
///
/// The expectations are the recorded `ntfscluster` cross-check in
/// `Tests/Fixtures/ntfs-disk-notes.md`: 16383 clusters, 12308 used, 4075 free,
/// 10 used runs, cluster size 4096. They are never recomputed by the code under
/// test. Every capture-backed test is `<skipped>` when the gitignored capture is
/// absent, never a pass.
struct ScopeReportTests {

    // MARK: - Stage 0 only

    // REQ-0221 / REQ-0222
    @Test(
        "REQ0221_REQ0222 a scope report runs stage 0 only and prints the allocation",
        .enabled(if: ntfsDiskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0221_REQ0222_scopeReportRunsStageZeroOnlyAndPrintsTheAllocation() throws {
        let harness = try ScopeReportHarness()
        let result = harness.run()

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        // REQ-0221: stage 0 only. No stage-1/2 argv is ever issued.
        let launches = harness.launcher.launches
        #expect(!launches.isEmpty, "the metadata read happened")
        #expect(launches.allSatisfy { $0.stage == 0 }, "only stage 0: \(launches.map(\.stage))")
        #expect(launches.allSatisfy { $0.domainPath?.hasSuffix(".domain-stage0.mapfile") == true })
        #expect(launches.allSatisfy { $0.pass == .metadata }, "no -n/-r3 in a scope report")
        let argvText = launches.map { $0.argv.joined(separator: " ") }.joined(separator: "\n")
        #expect(!argvText.contains("domain-stage1"), "no stage 1 argv: \(argvText)")
        #expect(!argvText.contains("domain-stage2"), "no stage 2 argv: \(argvText)")

        // REQ-0222: the recorded numbers.
        #expect(result.stdout.contains("total 16383"), "\(result.stdout)")
        #expect(result.stdout.contains("used 12308"), "\(result.stdout)")
        #expect(result.stdout.contains("free 4075"), "\(result.stdout)")
        #expect(result.stdout.contains("50413568"), "used bytes: \(result.stdout)")
        #expect(result.stdout.contains("16691200"), "free bytes: \(result.stdout)")
        #expect(result.stdout.contains("10 used extents"), "\(result.stdout)")
        #expect(result.stdout.contains("126976"), "$MFT bytes: \(result.stdout)")
        #expect(result.stdout.contains("primary"), "the geometry source: \(result.stdout)")
        #expect(result.stdout.contains("4096"), "the cluster size: \(result.stdout)")
        #expect(result.stdout.contains("stage 1 and stage 2 were not run"), "\(result.stdout)")
        // The failed-block caveat is text, not a number in the ETA.
        #expect(result.stdout.contains("48 s"), "\(result.stdout)")
    }

    // REQ-0221
    @Test(
        "REQ0221_REQ0224 a scope report that cannot read the bitmap exits 1 with the reason and no numbers",
        .enabled(if: ntfsDiskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0221_REQ0224_bitmapFailurePrintsTheReasonAndNoNumbers() throws {
        let harness = try ScopeReportHarness()
        // $Bitmap data lives at volume LCN 2055, one 4096-byte cluster.
        harness.zeroSourceRange(
            position: 1_048_576 + 2_055 * 4_096,
            length: 4_096
        )
        let result = harness.run()

        #expect(result.exitCode == 1, "nothing was learned: \(result.stdout)\n\(result.stderr)")
        #expect(result.stderr.contains("$Bitmap"), "the typed reason: \(result.stderr)")
        #expect(result.stderr.contains("nothing learned"), "\(result.stderr)")
        #expect(result.stdout.isEmpty, "no scope numbers are invented: \(result.stdout)")
        #expect(harness.launcher.launches.allSatisfy { $0.stage == 0 },
                "a failed stage 0 never starts stage 1 or 2")
        #expect(!harness.imageEqualsSource(), "the scope report read metadata only")
    }

    // REQ-0221
    @Test(
        "REQ0221 a backup boot sector supplies the same allocation",
        .enabled(if: ntfsDiskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0221_backupBootSectorSuppliesTheSameAllocation() throws {
        let harness = try ScopeReportHarness()
        harness.zeroSourceRange(position: 1_048_576, length: 512)
        let result = harness.run(extra: ["--json"])

        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        let report = try scopeReportObject(result.stdout)
        #expect(report["geometry_source"] as? String == "backup")
        #expect(report["used_clusters"] as? Int == 12_308)
        #expect(report["free_clusters"] as? Int == 4_075)
        #expect(report["used_bytes"] as? Int == 50_413_568)
    }

    // MARK: - JSON

    // REQ-0222 / REQ-0223
    @Test(
        "REQ0222_REQ0223 the JSON scope report has the stable keys and the recorded numbers",
        .enabled(if: ntfsDiskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0222_REQ0223_scopeReportJSONHasStableKeys() throws {
        let harness = try ScopeReportHarness()
        let result = harness.run(extra: ["--json"])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let report = try scopeReportObject(result.stdout)
        #expect(report["geometry_source"] as? String == "primary")
        #expect(report["cluster_bytes"] as? Int == 4_096)
        #expect(report["total_clusters"] as? Int == 16_383)
        #expect(report["used_clusters"] as? Int == 12_308)
        #expect(report["free_clusters"] as? Int == 4_075)
        #expect(report["used_bytes"] as? Int == 50_413_568)
        #expect(report["free_bytes"] as? Int == 16_691_200)
        #expect(report["used_extents"] as? Int == 10)
        #expect(report["mft_bytes"] as? Int == 126_976)
        // 50413568 / 37 MB/s and / 30 MB/s: the bus is the recorded synthetic USB.
        let low = try #require(report["eta_low_seconds"] as? Double)
        let high = try #require(report["eta_high_seconds"] as? Double)
        #expect(abs(low - 50_413_568.0 / 37_000_000.0) < 0.001)
        #expect(abs(high - 50_413_568.0 / 30_000_000.0) < 0.001)
        #expect((report["eta_basis"] as? String)?.contains("assumed USB") == true)
    }

    // MARK: - Preconditions and flag combinations

    // REQ-0225
    @Test("REQ0225 --scope-report with --used-only is a usage error")
    func REQ0225_scopeReportWithUsedOnlyIsUsageError() {
        let result = run(
            arguments: [
                "image", "disk8", "--to", "/tmp/x.img",
                "--confirm-serial", "ABCD", "--scope-report", "--used-only",
            ],
            executor: imagingExecutor(),
            destinationProbe: FakeImageProbe(facts: DestinationFacts(
                destinationExists: false,
                mapfileExists: false,
                freeBytes: 2_000_000_000_000,
                containerFilesystem: "apfs",
                parentIsWritable: true,
                backingWholeDisk: "disk0"
            ))
        )
        #expect(result.exitCode == 2, "\(result.stdout)\n\(result.stderr)")
        #expect(result.stderr.contains("--used-only"), "\(result.stderr)")
    }

    // REQ-0226
    @Test("REQ0226 a scope report needs the same consent and preconditions as a real run")
    func REQ0226_scopeReportNeedsTheSameGates() throws {
        // The gates are checked before any read, so this test needs no real
        // NTFS image and runs on every host.
        let bytes = Data(repeating: 0, count: 4 * 1_048_576)
        let noConsent = try ScopeReportHarness(sourceBytes: bytes)
        let refused = noConsent.run(acceptRisk: false)
        #expect(refused.exitCode == 2, "\(refused.stdout)\n\(refused.stderr)")
        #expect(refused.stderr.contains("--accept-risk"), "\(refused.stderr)")
        #expect(noConsent.launcher.launches.isEmpty, "no read before consent")

        let notRoot = try ScopeReportHarness(sourceBytes: bytes)
        notRoot.environment.root = false
        let rootRefused = notRoot.run()
        #expect(rootRefused.exitCode == 30, "\(rootRefused.stdout)\n\(rootRefused.stderr)")
        #expect(rootRefused.stderr.contains("root"), "\(rootRefused.stderr)")
        #expect(notRoot.launcher.launches.isEmpty)

        let noGuard = try ScopeReportHarness(sourceBytes: bytes)
        noGuard.environment.guardValue = .none
        let guardRefused = noGuard.run()
        #expect(guardRefused.exitCode == 30, "\(guardRefused.stdout)\n\(guardRefused.stderr)")
        #expect(guardRefused.stderr.contains("guard"), "\(guardRefused.stderr)")
        #expect(noGuard.launcher.launches.isEmpty)
    }

    // MARK: - Dry run

    // REQ-0221
    @Test("REQ0221 a scope-report dry run prints the stage-0 command and reads nothing")
    func REQ0221_dryRunPrintsTheStageZeroCommand() {
        let result = run(
            arguments: [
                "image", "disk8", "--to", "/tmp/x.img",
                "--confirm-serial", "ABCD", "--scope-report",
            ],
            executor: imagingExecutor(),
            destinationProbe: FakeImageProbe(facts: DestinationFacts(
                destinationExists: false,
                mapfileExists: false,
                freeBytes: 2_000_000_000_000,
                containerFilesystem: "apfs",
                parentIsWritable: true,
                backingWholeDisk: "disk0"
            ))
        )
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(result.stdout.contains("STAGE 0"), "\(result.stdout)")
        #expect(result.stdout.contains(".domain-stage0.mapfile"), "\(result.stdout)")
        #expect(result.stdout.contains("not run"), "stage 1/2 are named as not run")
        #expect(!result.stdout.contains(".domain-stage1.mapfile"), "\(result.stdout)")
        #expect(!result.stdout.contains(".domain-stage2.mapfile"), "\(result.stdout)")
    }

    // MARK: - Limit

    // REQ-0222
    @Test(
        "REQ0222 --limit reports the used bytes inside the limit separately",
        .enabled(if: ntfsDiskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0222_limitReportsUsedBytesInsideTheLimit() throws {
        let harness = try ScopeReportHarness()
        let limit: Int64 = 10 * 1_048_576
        let result = harness.run(extra: ["--json"], limitBytes: limit)
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let report = try #require(object["scope_report"] as? [String: Any])
        #expect(report["used_bytes"] as? Int == 50_413_568,
                "the full allocation is still reported")
        #expect(report["used_clusters"] as? Int == 12_308)
        #expect(object["limit_bytes"] as? Int == Int(limit))
        // The used runs clipped to [0, limit): clusters 0-2 and 4-2303.
        #expect(object["used_bytes_inside_limit"] as? Int == 9_433_088)
    }

    // MARK: - Sidecar and resume

    // REQ-0227
    @Test(
        "REQ0227 the sidecar records the scope report and a later full run resumes",
        .enabled(if: ntfsDiskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0227_sidecarRecordsTheReportAndAFullRunResumes() throws {
        let harness = try ScopeReportHarness()
        let reportRun = harness.run()
        #expect(reportRun.exitCode == 0, "\(reportRun.stdout)\n\(reportRun.stderr)")

        let sidecar = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: harness.image + ".disktriage.json"))
            ) as? [String: Any]
        )
        let recorded = try #require(sidecar["scope_report"] as? [String: Any])
        #expect(recorded["geometry_source"] as? String == "primary")
        #expect(recorded["used_clusters"] as? Int == 12_308)
        #expect(recorded["used_bytes"] as? Int == 50_413_568)
        #expect(recorded["used_extents"] as? Int == 10)
        #expect(recorded["mft_bytes"] as? Int == 126_976)
        let allocation = try #require(sidecar["allocation"] as? [String: Any])
        #expect(allocation["mode"] as? String == "allocation-aware")
        #expect(allocation["stage0"] as? String == "done")
        #expect(allocation["stage1"] as? String == "not-started")
        #expect(allocation["stage2"] as? String == "not-started")

        // A later full run resumes from the sidecar and completes.
        harness.launcher.reset()
        let resumed = harness.run(extra: [], scopeReport: false)
        #expect(resumed.exitCode == 0, "\(resumed.stdout)\n\(resumed.stderr)")
        #expect(harness.launcher.launches.contains { $0.stage == 1 }, "stage 1 ran")
        #expect(harness.launcher.launches.contains { $0.stage == 2 }, "stage 2 ran")
        #expect(harness.imageEqualsSource(), "the resumed image is the whole device")
    }
}

// MARK: - The harness

private final class ScopeReportHarness {
    private let temp = TempDir()
    let directory: String
    let source: String
    let image: String
    let deviceSize: Int64
    let launcher: StageFakeDdrescueLauncher
    let environment = FakeImagingEnvironment()
    var mapfile: String { image + ".mapfile" }

    init(sourceBytes: Data? = nil) throws {
        directory = temp.path
        source = directory + "/device.bin"
        image = directory + "/disk.img"
        let bytes: Data
        if let sourceBytes {
            bytes = sourceBytes
        } else {
            let capture = try #require(
                ntfsDiskImagePath(),
                "run scripts/bootstrap.sh to build the NTFS fixtures"
            )
            bytes = try Data(contentsOf: URL(fileURLWithPath: capture))
        }
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

    func run(
        extra: [String] = [],
        limitBytes: Int64? = nil,
        scopeReport: Bool = true,
        acceptRisk: Bool = true
    ) -> CLIResult {
        var arguments = ["disk8", "--to", image, "--no-dry-run", "--confirm-serial", "ABCD"]
        if scopeReport { arguments.append("--scope-report") }
        if acceptRisk { arguments.append("--accept-risk") }
        arguments += extra
        let dependencies = ImagingDependencies(
            environment: environment,
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

// MARK: - Helpers

private func scopeReportObject(_ stdout: String) throws -> [String: Any] {
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
    )
    return try #require(object["scope_report"] as? [String: Any])
}

// MARK: - The real ddrescue

/// Runs the exact argv the wrapper built with the capture file in place of
/// `/dev/rdiskN`. The precondition path is already covered by the fake tests;
/// this proves the real ddrescue 1.30 integration of stage 0 only.
private struct ScopeRealDdrescueLauncher: DdrescueLaunching {
    let sourcePath: String
    private let inner = PosixDdrescueLauncher()
    private let log: LaunchLog

    init(sourcePath: String, log: LaunchLog) {
        self.sourcePath = sourcePath
        self.log = log
    }

    func launch(argv: [String]) throws -> any DdrescueProcessHandle {
        log.record(argv)
        var rewritten = argv
        if rewritten.count >= 3 {
            rewritten[rewritten.count - 3] = sourcePath
        }
        return try inner.launch(argv: rewritten)
    }
}

private final class LaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    func record(_ argv: [String]) {
        lock.lock()
        stored.append(argv)
        lock.unlock()
    }

    var argvs: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// One real ddrescue 1.30 test on a regular-file copy of the capture. It is
/// `<skipped>` when ddrescue or the capture is absent — never a pass.
struct ScopeReportLiveTests {

    // REQ-0221 / REQ-0222
    @Test(
        "REQ0221_REQ0222 real ddrescue 1.30 stage 0 reports the recorded allocation",
        .enabled(
            if: ntfsDiskImagePath() != nil && scopeDdrescuePath() != nil,
            "ddrescue or the bootstrap NTFS fixture absent"
        )
    )
    func REQ0221_REQ0222_realDdrescueStageZeroReportsTheRecordedAllocation() throws {
        let harness = try ScopeLiveHarness()
        let result = harness.run(extra: ["--json"])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let report = try scopeReportObject(result.stdout)
        #expect(report["geometry_source"] as? String == "primary")
        #expect(report["cluster_bytes"] as? Int == 4_096)
        #expect(report["total_clusters"] as? Int == 16_383)
        #expect(report["used_clusters"] as? Int == 12_308)
        #expect(report["free_clusters"] as? Int == 4_075)
        #expect(report["used_bytes"] as? Int == 50_413_568)
        #expect(report["used_extents"] as? Int == 10)
        #expect(report["mft_bytes"] as? Int == 126_976)

        // Real ddrescue was the reader, and only stage 0 ran.
        #expect(!harness.log.argvs.isEmpty)
        #expect(harness.log.argvs.allSatisfy { argv in
            !argv.contains { $0.contains("domain-stage1") || $0.contains("domain-stage2") }
        })
        let attributes = try FileManager.default.attributesOfItem(atPath: harness.image)
        let imageBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        #expect(imageBytes < harness.deviceSize, "a metadata-only image, not the device")
    }

    // REQ-0237
    @Test(
        "REQ0237 a scope-report image on APFS is sparse: small allocated blocks, large apparent size",
        .enabled(
            if: ntfsDiskImagePath() != nil && scopeDdrescuePath() != nil
                && temporaryDirectoryIsAPFS(),
            "ddrescue, the capture, or an APFS temp directory is absent"
        )
    )
    func REQ0237_realDdrescueScopeReportImageIsSparse() throws {
        let harness = try ScopeLiveHarness()
        // The plan's transcript: a 233.8 GiB device into 1.3 GiB of free
        // space. The source file stays the capture; the seam reports the full
        // size, which only a sparse metadata-only image can fit.
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 1_396_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
        let result = harness.run(
            deviceSizeOverride: 251_000_193_024,
            probe: DiskDestinationProbe(freeBytes: facts.freeBytes, containerFilesystem: "apfs")
        )
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        var info = stat()
        #expect(lstat(harness.image, &info) == 0, "the image exists")
        let allocated = Int64(info.st_blocks) * 512
        let apparent = Int64(info.st_size)
        #expect(apparent > 0)
        #expect(allocated < apparent,
                "the image is sparse: \(allocated) allocated vs \(apparent) apparent")
        #expect(allocated < 8 * 1_048_576,
                "stage 0 wrote metadata only, not the 233.8 GiB device")
    }
}

private func temporaryDirectoryIsAPFS() -> Bool {
    var stats = statfs()
    let path = FileManager.default.temporaryDirectory.path
    guard path.withCString({ statfs($0, &stats) }) == 0 else { return false }
    let name = withUnsafeBytes(of: stats.f_fstypename) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return name == "apfs"
}

private final class ScopeLiveHarness {
    private let temp = TempDir()
    let directory: String
    let source: String
    let image: String
    let deviceSize: Int64
    let log = LaunchLog()

    init() throws {
        let capture = try #require(ntfsDiskImagePath(), "run scripts/bootstrap.sh to build the NTFS fixtures")
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
        #expect(deviceSize > 0)
    }

    func run(
        extra: [String] = [],
        deviceSizeOverride: Int64? = nil,
        probe: (any ImageDestinationProbing)? = nil
    ) -> CLIResult {
        let dependencies = ImagingDependencies(
            environment: FakeImagingEnvironment(),
            launcher: ScopeRealDdrescueLauncher(sourcePath: source, log: log),
            pollInterval: 0.02,
            allocationAware: true,
            readImage: readImageFile
        )
        return DiskTriageCLI.image(
            ["disk8", "--to", image, "--no-dry-run", "--accept-risk",
             "--confirm-serial", "ABCD", "--scope-report"] + extra,
            executor: imagingExecutor(),
            now: { Date() },
            destinationProbe: probe ?? DiskDestinationProbe(),
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: dependencies,
            deviceSizeOverride: deviceSizeOverride ?? deviceSize
        )
    }
}

private func scopeDdrescuePath() -> String? {
    TestFixtures.ddrescueExecutable()
}
