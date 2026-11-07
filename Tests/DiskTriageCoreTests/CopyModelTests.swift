import Foundation
import Testing
import DiskTriageCore

/// The pure half of `copy`: mapfile bytes → volume clusters → the inodes that
/// own them, plus the manifest model. The fixtures are real `ntfsls` /
/// `ntfscluster` / `ntfscat` output from the ntfs-3g spike recorded in
/// `Tests/Fixtures/ntfs*-copy.*` and `ntfscat-copy-*.bin`.
struct CopyModelTests {

    private static func fixture(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    private static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DiskTriageCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/\(name)")
    }

    // MARK: - Cluster math

    // REQ-0135: a partly bad cluster is wholly bad.
    @Test("REQ0135 a partial cluster rounds outward to the whole cluster")
    func REQ0135_partialClusterRoundsOutward() throws {
        func range(_ position: Int64, _ size: Int64) throws -> ClusterRange {
            try #require(CopyExtentMath.clusterRange(
                for: ByteRange(position: position, size: size),
                partitionOffset: 0,
                clusterSize: 4096
            ))
        }

        let firstByte = try range(0, 1)
        #expect(firstByte.first == 0 && firstByte.last == 0)

        let lastByteOfCluster = try range(4095, 1)
        #expect(lastByteOfCluster.first == 0 && lastByteOfCluster.last == 0)

        let straddles = try range(4095, 2)
        #expect(straddles.first == 0 && straddles.last == 1, "the second cluster is touched too")

        let second = try range(4096, 1)
        #expect(second.first == 1 && second.last == 1)
    }

    // REQ-0135: image bytes are not volume bytes when a partition sits in front.
    @Test("REQ0135 the partition offset is subtracted before dividing")
    func REQ0135_partitionOffsetIsSubtracted() throws {
        let atPartitionStart = try #require(CopyExtentMath.clusterRange(
            for: ByteRange(position: 1_048_576, size: 4096),
            partitionOffset: 1_048_576,
            clusterSize: 4096
        ))
        #expect(atPartitionStart.first == 0 && atPartitionStart.last == 0)

        let twoClustersIn = try #require(CopyExtentMath.clusterRange(
            for: ByteRange(position: 1_048_576 + 8192, size: 1),
            partitionOffset: 1_048_576,
            clusterSize: 4096
        ))
        #expect(twoClustersIn.first == 2 && twoClustersIn.last == 2)
    }

    @Test("an extent starting at or after the volume end is dropped")
    func extentAfterTheVolumeEndIsDropped() throws {
        let last = try #require(CopyExtentMath.clusterRange(
            for: ByteRange(position: 9 * 4096, size: 4096),
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 10
        ))
        #expect(last.first == 9 && last.last == 9)

        #expect(CopyExtentMath.clusterRange(
            for: ByteRange(position: 10 * 4096, size: 4096),
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 10
        ) == nil, "the first cluster after the volume is not part of it")
    }

    @Test("an extent that starts before the volume is clipped to cluster 0")
    func extentBeforeTheVolumeStartsIsClipped() throws {
        let clipped = try #require(CopyExtentMath.clusterRange(
            for: ByteRange(position: 0, size: 8192),
            partitionOffset: 4096,
            clusterSize: 4096,
            volumeClusters: 10
        ))
        #expect(clipped.first == 0 && clipped.last == 0)
    }

    // MARK: - Intersection

    private static func run(_ inode: Int, _ path: String, _ first: Int64, _ last: Int64) -> NTFSVolumeRun {
        NTFSVolumeRun(
            inode: inode,
            path: path,
            attribute: "0x80",
            firstLCN: first,
            lastLCN: last
        )
    }

    @Test("REQ0140 one bad extent that straddles two files names both")
    func REQ0140_extentStraddlingTwoFilesNamesBoth() {
        let attribution = CopyAttributionEngine.attribute(
            badExtents: [ByteRange(position: 0, size: 4 * 4096)],
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 32,
            runs: [
                Self.run(10, "/first.bin/$DATA", 0, 1),
                Self.run(11, "/second.bin/$DATA", 2, 3),
            ],
            filePaths: ["/first.bin", "/second.bin"]
        )

        #expect(attribution.kind == "ntfscluster")
        #expect(attribution.integrity["/first.bin"] == .overlapsBadExtent)
        #expect(attribution.integrity["/second.bin"] == .overlapsBadExtent)
        #expect(attribution.filesOverlapping == 2)
    }

    @Test("an extent in a gap names no file")
    func extentInAGapNamesNoFile() {
        let attribution = CopyAttributionEngine.attribute(
            badExtents: [ByteRange(position: 10 * 4096, size: 4096)],
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 32,
            runs: [
                Self.run(10, "/before.bin/$DATA", 0, 3),
                Self.run(11, "/after.bin/$DATA", 20, 23),
            ],
            filePaths: ["/before.bin", "/after.bin"]
        )

        #expect(attribution.integrity["/before.bin"] == .intact)
        #expect(attribution.integrity["/after.bin"] == .intact)
        #expect(attribution.filesOverlapping == 0)
        #expect(attribution.unattributedRanges == [ClusterRange(first: 10, last: 10)])
    }

    // The plan's load-bearing rule: never merge extents into one min-max span.
    @Test("REQ0139 a good gap between two bad extents is not flagged")
    func REQ0139_goodGapBetweenBadExtentsStaysIntact() {
        let attribution = CopyAttributionEngine.attribute(
            badExtents: [
                ByteRange(position: 0, size: 4096),
                ByteRange(position: 20 * 4096, size: 4096),
            ],
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 32,
            runs: [
                Self.run(10, "/bad-a.bin/$DATA", 0, 0),
                Self.run(11, "/gap.bin/$DATA", 10, 10),
                Self.run(12, "/bad-b.bin/$DATA", 20, 20),
            ],
            filePaths: ["/bad-a.bin", "/gap.bin", "/bad-b.bin"]
        )

        #expect(attribution.integrity["/bad-a.bin"] == .overlapsBadExtent)
        #expect(attribution.integrity["/bad-b.bin"] == .overlapsBadExtent)
        #expect(attribution.integrity["/gap.bin"] == .intact,
                "merging the extents into 0-20 would wrongly flag the good gap")
    }

    @Test("metadata runs are named verbatim and their directory children are metadata-damaged")
    func metadataIsNamedAndLocalised() {
        let attribution = CopyAttributionEngine.attribute(
            badExtents: [ByteRange(position: 5 * 4096, size: 4096)],
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 32,
            runs: [
                Self.run(66, "/media/$INDEX_ALLOCATION($I30)", 5, 5),
                Self.run(77, "/media/clip.dat/$DATA", 20, 23),
                Self.run(78, "/docs/readme.txt/$DATA", 24, 24),
            ],
            filePaths: ["/media/clip.dat", "/docs/readme.txt"]
        )

        #expect(attribution.metadataPaths == ["/media/$INDEX_ALLOCATION($I30)"])
        #expect(attribution.integrity["/media/clip.dat"] == .metadataDamaged)
        #expect(attribution.integrity["/docs/readme.txt"] == .intact)
        #expect(attribution.filesMetadataDamaged == 1)
    }

    @Test("$MFT metadata is reported at volume level, not attributed to files")
    func mftIsVolumeLevel() {
        let attribution = CopyAttributionEngine.attribute(
            badExtents: [ByteRange(position: 4 * 4096, size: 4096)],
            partitionOffset: 0,
            clusterSize: 4096,
            volumeClusters: 32,
            runs: [Self.run(0, "/$MFT/$DATA", 4, 34)],
            filePaths: ["/readme.txt"]
        )

        #expect(attribution.metadataPaths == ["/$MFT/$DATA"])
        #expect(attribution.integrity["/readme.txt"] == .intact,
                "$MFT damage is volume-level: no per-file claim follows from it")
        #expect(attribution.filesMetadataDamaged == 0)
    }

    // MARK: - ntfscluster parser

    @Test("the real ntfscluster -v output parses to inode runs")
    func parsesTheRealClusterOutput() throws {
        let map = NTFSClusterOutputParser.parse(try Self.fixture("ntfscluster-copy.txt"))
        #expect(!map.truncated)
        #expect(map.inodeCount == 11)
        #expect(map.runs.count == 13)

        let first = try #require(map.runs.first)
        #expect(first.inode == 0)
        #expect(first.path == "/$MFT/$DATA")
        #expect(first.firstLCN == 4)
        #expect(first.lastLCN == 22)

        let payload = try #require(map.runs.first { $0.path == "/payload.bin/$DATA" })
        #expect(payload.inode == 68)
        #expect(payload.firstLCN == 2560)
        #expect(payload.lastLCN == 2591)

        let docsPayload = try #require(map.runs.first { $0.path == "/docs/payload.bin/$DATA" })
        #expect(docsPayload.inode == 69)
        #expect(docsPayload.firstLCN == 2592)
        #expect(docsPayload.lastLCN == 2596)
    }

    @Test("the run cap marks the map truncated instead of guessing")
    func runCapTruncates() throws {
        let map = NTFSClusterOutputParser.parse(
            try Self.fixture("ntfscluster-copy.txt"),
            maxRuns: 2
        )
        #expect(map.truncated)
        #expect(map.runs.count <= 2)
    }

    @Test("owner paths separate file data from metadata")
    func ownershipSeparatesDataFromMetadata() {
        func owner(_ path: String) -> CopyRunOwner {
            CopyRunOwnership.owner(of: NTFSVolumeRun(
                inode: 1, path: path, attribute: "0x80", firstLCN: 1, lastLCN: 1
            ))
        }

        #expect(owner("/media/big.bin/$DATA") == .file(path: "/media/big.bin"))
        #expect(owner("/$MFT/$DATA") == .metadata(path: "/$MFT/$DATA"))
        #expect(owner("/./$INDEX_ALLOCATION($I30)") == .metadata(path: "/./$INDEX_ALLOCATION($I30)"))
        #expect(owner("/media/$INDEX_ALLOCATION($I30)")
            == .directoryMetadata(path: "/media/$INDEX_ALLOCATION($I30)", directory: "/media"))
    }

    // MARK: - Listing

    @Test("the real -l -R listing yields sizes and every directory, including empty ones")
    func parsesTheRealLongRecursiveListing() throws {
        let listing = NTFSListingParser.parse(try Self.fixture("ntfsls-copy.txt"))
        #expect(listing.directories.contains("/"))
        #expect(listing.directories.contains("/docs"))

        let paths = listing.entries.map { listing.volumePath(for: $0) }
        #expect(paths.contains("/readme.txt"))
        #expect(paths.contains("/docs/notes.md"))
        #expect(paths.contains("/payload.bin"))

        let readme = try #require(listing.entries.first { $0.name == "readme.txt" })
        #expect(readme.sizeBytes == 24, "the recorded readme is 24 bytes")
        #expect(readme.directory == "/")
    }

    // MARK: - Paths

    // REQ-0127: a transferred name is never allowed to escape the destination.
    @Test("REQ0127 path traversal, absolute and NUL names are refused")
    func REQ0127_refusesUnsafeNames() {
        #expect(CopyPathRules.isSafe("/docs/notes.md"))
        #expect(CopyPathRules.isSafe("docs/notes.md"))
        #expect(!CopyPathRules.isSafe("../evil"))
        #expect(!CopyPathRules.isSafe("/docs/../evil"))
        #expect(!CopyPathRules.isSafe("docs//notes.md"))
        #expect(!CopyPathRules.isSafe("/docs/\0evil"))
        #expect(!CopyPathRules.isSafe("/"))
    }

    // MARK: - Manifest

    // REQ-0136: the manifest carries the schema, damage scope and per-file hashes.
    @Test("REQ0136 the manifest renders its stable keys and null image hash")
    func REQ0136_manifestKeys() throws {
        let entry = CopyManifestEntry(
            path: "docs/notes.md",
            sizeBytes: 27,
            sha256Read: "read-hash",
            sha256Written: "read-hash",
            integrity: .intact,
            attribution: "ntfscluster",
            status: "ok",
            note: nil
        )
        let manifest = CopyManifest(
            createdAt: "2026-11-07T09:00:00Z",
            image: .init(
                path: "/images/plain.img",
                sizeBytes: 67_108_864,
                sha256: nil,
                sha256Note: "not computed: pass --hash-image"
            ),
            source: .init(
                mapfile: "/images/plain.img.mapfile",
                unreadableExtents: 1,
                unreadableBytes: 262_144,
                limitBytes: nil,
                remainingBytes: 0
            ),
            damage: .init(
                status: "ok",
                unreadableExtents: 1,
                unreadableBytes: 262_144,
                limitBytes: nil,
                note: "unreadable regions are zero-filled"
            ),
            attribution: CopyAttribution(
                kind: "ntfscluster",
                reason: nil,
                integrity: ["/docs/notes.md": .intact],
                metadataPaths: [],
                unattributedRanges: [],
                badRanges: [ClusterRange(first: 5, last: 5)!],
                filesClaimed: 1,
                filesOverlapping: 0,
                filesMetadataDamaged: 0
            ),
            copy: .init(
                status: "ok",
                filesCopied: 1,
                filesFailed: 0,
                bytesRead: 27,
                bytesWritten: 27,
                hashesAgree: true,
                manifestSHA256: "digest"
            ),
            entries: [entry],
            notes: ["hash equality proves the copy matches the IMAGE, not the platter"]
        )

        let object = manifest.jsonObject()
        #expect(object["schema"] as? String == "disktriage.copy/1")
        #expect(object["version"] as? Int == 1)
        #expect(object["image_sha256"] is NSNull, "absent is recorded as null, never omitted as zero")
        #expect((object["image_sha256_note"] as? String)?.contains("--hash-image") == true)

        let image = try #require(object["image"] as? [String: Any])
        #expect(image["size_bytes"] as? Int64 == 67_108_864)

        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["scope"] as? String == "volume")
        #expect(damage["unreadable_extents"] as? Int == 1)
        #expect(damage["unreadable_bytes"] as? Int64 == 262_144)

        let attribution = try #require(object["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "ntfscluster")

        let files = try #require(object["files"] as? [[String: Any]])
        #expect(files.count == 1)
        #expect(files[0]["path"] as? String == "docs/notes.md")
        #expect(files[0]["sha256_read"] as? String == "read-hash")
        #expect(files[0]["sha256_written"] as? String == "read-hash")
        #expect(files[0]["integrity"] as? String == "intact")
        #expect(files[0]["attribution"] as? String == "ntfscluster")

        // The JSON is what is written to MANIFEST.json; it must round-trip.
        let data = try manifest.jsonData()
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["schema"] as? String == "disktriage.copy/1")
    }
}
