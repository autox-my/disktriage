import Foundation
import Testing
import DiskTriageCore

/// The `$Bitmap` trust rule for stage 0 (diskdoctor.md §8, "Allocation-aware
/// order for NTFS"): a bitmap byte the mapfile did not finish is not evidence
/// that its eight clusters are free. The expectations are hand arithmetic from
/// the extent table, never recomputed through the code under test.
struct NTFSBitmapTrustTests {

    // MARK: - 1. The untrustworthy bitmap bytes

    // REQ-0238
    @Test("REQ0238 the untrustworthy bytes are the unfinished intersection with the bitmap runs")
    func REQ0238_untrustworthyBytesAreTheUnfinishedBitmapIntersection() {
        struct Case {
            let name: String
            let runs: [ByteRange]
            let unfinished: [ByteRange]
            let clusters: Int64
            let byteRanges: [ByteRange]
            let clusterRanges: [ClusterRange]
        }

        let cases = [
            Case(
                name: "a fully read bitmap has no unknown bytes",
                runs: [ByteRange(position: 0x1000, size: 0x100)],
                unfinished: [],
                clusters: 2048,
                byteRanges: [],
                clusterRanges: []
            ),
            Case(
                name: "a 16-byte sub-sector hole hides 128 clusters",
                runs: [ByteRange(position: 0x1000, size: 0x2000)],
                unfinished: [ByteRange(position: 0x1100, size: 0x10)],
                clusters: 4096,
                byteRanges: [ByteRange(position: 0x100, size: 0x10)],
                clusterRanges: [ClusterRange(first: 2_048, last: 2_175)!]
            ),
            Case(
                name: "one hole straddling two device runs is contiguous in bitmap order",
                runs: [
                    ByteRange(position: 0x1000, size: 0x100),
                    ByteRange(position: 0x5000, size: 0x100),
                ],
                unfinished: [ByteRange(position: 0x10F0, size: 0x3F20)],
                clusters: 4096,
                byteRanges: [ByteRange(position: 0xF0, size: 0x20)],
                clusterRanges: [ClusterRange(first: 1_920, last: 2_175)!]
            ),
            Case(
                name: "a hole past the bitmap end is clipped to the volume's clusters",
                runs: [ByteRange(position: 0x1000, size: 0x100)],
                unfinished: [ByteRange(position: 0x10F0, size: 0x100)],
                clusters: 2_000,
                byteRanges: [ByteRange(position: 0xF0, size: 0x10)],
                clusterRanges: [ClusterRange(first: 1_920, last: 1_999)!]
            ),
        ]

        for item in cases {
            let trust = NTFSBitmapTrust.unreadable(
                bitmapRuns: item.runs,
                unfinished: item.unfinished,
                clusterBytes: 4_096,
                totalClusters: item.clusters
            )
            #expect(trust.byteRanges == item.byteRanges, "\(item.name): bytes")
            #expect(trust.clusters == item.clusterRanges, "\(item.name): clusters")
            #expect(trust.bitmapBytes == item.byteRanges.reduce(0) { $0 + $1.size },
                    "\(item.name): byte count")
            #expect(trust.clusterCount == item.clusterRanges.reduce(0) { $0 + $1.count },
                    "\(item.name): cluster count")
        }
    }

    // MARK: - 2. Unknown clusters are stage-1 used, never free

    // REQ-0239
    @Test("REQ0239 unknown clusters join the stage-1 used domain and leave free")
    func REQ0239_unknownClustersJoinTheStageOneUsedDomain() throws {
        let geometry = try NTFSBootGeometry.parse(
            try bitmapTrustFixture("ntfs-disk-boot-primary.bin")
        ).get()
        let mftRecord = try bitmapTrustFixture("ntfs-disk-mft-record-0.bin")
        let bitmapRecord = try bitmapTrustFixture("ntfs-disk-mft-record-6.bin")
        let bitmapData = try bitmapTrustFixture("ntfs-disk-bitmap.bin")
        let usedClusters = try NTFSBitmap.usedClusters(
            bitmapData,
            totalClusters: geometry.totalClusters
        ).get()
        // Volume-relative clusters 3800-3927 are bitmap-free on the spike image
        // (the used runs there are 4-3710 and 4201-5224).
        let unknown = [try #require(ClusterRange(first: 3_800, last: 3_927))]
        let unknownBytes: Int64 = 128 * 4_096

        let domain = try NTFSAllocation.allocationDomain(
            geometry: geometry,
            mftRuns: NTFSMFTRecord.dataAttribute(
                in: mftRecord,
                bytesPerSector: geometry.bytesPerSector,
                volumeClusters: geometry.totalClusters
            ).get().runs,
            usedClusters: usedClusters,
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864,
            unknownClusters: unknown
        ).get()

        #expect(domain.usedClusters.reduce(0) { $0 + $1.count } == 12_308,
                "the bitmap's own used count is unchanged")
        #expect(domain.unknownClusters == unknown)
        #expect(domain.stage1Clusters.reduce(0) { $0 + $1.count } == 12_436,
                "stage 1 is used plus unknown")
        #expect(domain.used.reduce(0) { $0 + $1.size } == 50_413_568 + unknownBytes,
                "the unknown clusters are in the stage-1 domain")
        let unknownExtent = ByteRange(
            position: 1_048_576 + 3_800 * 4_096,
            size: unknownBytes
        )
        #expect(domain.used.contains { $0.position <= unknownExtent.position
            && $0.end >= unknownExtent.end }, "stage 1 covers the unknown clusters")
        #expect(!domain.free.contains { $0.position < unknownExtent.end
            && unknownExtent.position < $0.end }, "free space excludes them")
        #expect(domain.free.reduce(0) { $0 + $1.size } == 16_695_296 - unknownBytes,
                "the device free count drops by the unknown bytes")
    }
}

private func bitmapTrustFixture(_ name: String) throws -> Data {
    let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: path)
}
