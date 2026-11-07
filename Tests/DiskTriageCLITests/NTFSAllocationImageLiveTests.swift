import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCore
import DiskTriageCollectors
@testable import DiskTriageCLI

/// The real ddrescue 1.30 half of the allocation-aware `image` work. Each test
/// is `<skipped>` when ddrescue or the gitignored spike image is absent — never
/// a pass; `scripts/check.sh` answers 3 for a skipped case.
struct NTFSAllocationImageLiveTests {

    // REQ-0213
    @Test(
        "REQ0213 default staging images the whole device byte for byte",
        .enabled(if: liveAllocationAvailable(), "ddrescue or captures/ntfs-spike/img/disk.img absent")
    )
    func REQ0213_defaultStagingReproducesTheDevice() throws {
        let harness = try RealAllocationHarness()
        let result = harness.run()
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(try sha256(harness.image) == sha256(harness.source),
                "the staged image is the device, byte for byte")
        #expect(result.stdout.contains("SCOPE"))
        #expect(result.stdout.contains("whole device"))
    }

    // REQ-0214
    @Test(
        "REQ0214 --used-only copies every used cluster and leaves free clusters zero",
        .enabled(if: liveAllocationAvailable(), "ddrescue or captures/ntfs-spike/img/disk.img absent")
    )
    func REQ0214_usedOnlyCopiesUsedClustersAndNoFreeSpace() throws {
        let harness = try RealAllocationHarness()
        let result = harness.run(extra: ["--used-only"])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let used = try usedClusterRanges()
        for range in used {
            for cluster in range.first...range.last {
                #expect(clusterBytes(harness.image, cluster: cluster)
                    == clusterBytes(harness.source, cluster: cluster),
                    "used cluster \(cluster) equals the device")
            }
        }

        // The free clusters are the complement inside the volume.
        let free = freeClusters(used: used, totalClusters: 16_383)
        #expect(!free.isEmpty)
        for cluster in free.prefix(64) {
            #expect(clusterBytes(harness.image, cluster: cluster).allSatisfy { $0 == 0 },
                    "free cluster \(cluster) was not imaged")
        }
        #expect(result.stdout.contains("used clusters + metadata"))
        #expect(result.stdout.contains("free space NOT imaged"))
    }

    // REQ-0215
    @Test(
        "REQ0215 a zeroed primary boot sector uses the backup and keeps every used cluster",
        .enabled(if: liveAllocationAvailable(), "ddrescue or captures/ntfs-spike/img/disk.img absent")
    )
    func REQ0215_backupBootSectorLive() throws {
        let harness = try RealAllocationHarness()
        harness.zeroSourceRange(position: 1_048_576, length: 512)
        let result = harness.run(extra: ["--json", "--used-only"])
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let allocation = try #require(object["allocation"] as? [String: Any])
        #expect(allocation["geometry_source"] as? String == "backup")

        for range in try usedClusterRanges() {
            for cluster in range.first...range.last {
                #expect(clusterBytes(harness.image, cluster: cluster)
                    == clusterBytes(harness.source, cluster: cluster),
                    "used cluster \(cluster) equals the modified device")
            }
        }
    }
}

// MARK: - Harness

private final class RealAllocationHarness {
    private let temp = TempDir()
    let directory: String
    let source: String
    let image: String
    let deviceSize: Int64

    init() throws {
        let capture = try #require(ntfsDiskImagePath())
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

    func zeroSourceRange(position: Int64, length: Int) {
        let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: source))
        defer { try? handle?.close() }
        try? handle?.seek(toOffset: UInt64(position))
        try? handle?.write(contentsOf: Data(repeating: 0, count: length))
    }

    func run(extra: [String] = []) -> CLIResult {
        let dependencies = ImagingDependencies(
            environment: FakeImagingEnvironment(),
            launcher: RealDdrescueOnFileLauncher(sourcePath: source),
            pollInterval: 0.02,
            allocationAware: true,
            readImage: readImageFile
        )
        return DiskTriageCLI.image(
            ["disk8", "--to", image, "--no-dry-run", "--accept-risk",
             "--confirm-serial", "ABCD"] + extra,
            executor: imagingExecutor(),
            now: { Date() },
            destinationProbe: DiskDestinationProbe(),
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: dependencies,
            deviceSizeOverride: deviceSize
        )
    }
}

/// Runs the exact argv the dry run printed, but with the source file in place
/// of `/dev/rdiskN`. The identity/precondition path is already driven by the
/// fake-executor tests; this proves the ddrescue integration itself.
private struct RealDdrescueOnFileLauncher: DdrescueLaunching {
    let sourcePath: String
    private let inner = PosixDdrescueLauncher()

    func launch(argv: [String]) throws -> any DdrescueProcessHandle {
        var rewritten = argv
        if rewritten.count >= 3 {
            rewritten[rewritten.count - 3] = sourcePath
        }
        return try inner.launch(argv: rewritten)
    }
}

// MARK: - Bytes

private func sha256(_ path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The volume-relative cluster range at device bytes. A missing tail is zero,
/// exactly as an unimaged hole reads through the filesystem.
private func clusterBytes(_ path: String, cluster: Int64) -> Data {
    let offset = 1_048_576 + cluster * 4096
    var data = readImageFile(path, offset, 4096) ?? Data()
    if data.count < 4096 {
        data.append(Data(repeating: 0, count: 4096 - data.count))
    }
    return data
}

private func usedClusterRanges() throws -> [ClusterRange] {
    let text = String(
        decoding: try Data(contentsOf: URL(fileURLWithPath: fixturePath("ntfs-disk-used-runs.txt"))),
        as: UTF8.self
    )
    return text.split(separator: "\n").compactMap { rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        let parts = line.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let first = Int64(parts[0]),
              let last = Int64(parts[1])
        else { return nil }
        return ClusterRange(first: first, last: last)
    }
}

private func freeClusters(used: [ClusterRange], totalClusters: Int64) -> [Int64] {
    var free: [Int64] = []
    var cursor: Int64 = 0
    for range in used.sorted() {
        if range.first > cursor {
            free += Array(cursor..<range.first)
        }
        cursor = max(cursor, range.last + 1)
    }
    if cursor < totalClusters {
        free += Array(cursor..<totalClusters)
    }
    return free
}

// MARK: - Availability

private func liveAllocationAvailable() -> Bool {
    ntfsDiskImagePath() != nil && ddrescueExecutablePath() != nil
}

private func ddrescueExecutablePath() -> String? {
    var candidates = [
        "/opt/homebrew/bin/ddrescue",
        "/usr/local/bin/ddrescue",
        "/usr/bin/ddrescue",
    ]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        candidates += path.split(separator: ":").map { String($0) + "/ddrescue" }
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
