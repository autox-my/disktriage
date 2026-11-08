import Foundation
import Testing
import DiskTriageTestSupport
import DiskTriageCore
@testable import DiskTriageCLI

/// The live half of the NTFS allocation-domain work: the ddrescue DOMAIN
/// MAPFILE writer round-trips through the shipped parser, ddrescue 1.30 itself
/// copies only the domain extents, and the real spike image's `$Bitmap`
/// agrees with the recorded `ntfscluster` output.
///
/// Each live test is reported as **skipped** when its tool or the bootstrap
/// fixture is absent, never as a pass; `scripts/check.sh` answers 3 for a
/// `<skipped>` case. The pure tests for the same rules are in
/// `DiskTriageCoreTests.NTFSAllocationTests`.
struct NTFSAllocationLiveTests {
    private let temp = TempDir()


    // MARK: - 5. Domain mapfile

    // REQ-0196
    @Test("REQ0196 a domain mapfile is + for the domain and ? for the rest, and parses back")
    func REQ0196_domainMapfileRoundTripsThroughTheParser() throws {
        let deviceSize: Int64 = 8 * 1_048_576
        let domain = [
            ByteRange(position: 3 * 1_048_576, size: 524_288),
            ByteRange(position: 0, size: 2 * 1_048_576),   // overlaps and extends
        ]
        let text = DdrescueDomainMapfile.render(domain: domain, deviceSize: deviceSize)

        #expect(text.contains("# Mapfile. Created by disktriage"))
        #expect(text.contains("# current_pos"))
        #expect(text.contains("  ?  "))

        let snapshot = try #require(DdrescueMapfile.parse(text))
        #expect(snapshot.extents.map(\.status) == ["+", "?", "+", "?"])
        #expect(snapshot.extents.map(\.position) == [0, 2_097_152, 3_145_728, 3_670_016])
        #expect(snapshot.extents.map(\.size) == [2_097_152, 1_048_576, 524_288, 4_718_592])
        #expect(snapshot.rescuedBytes == 2_621_440)
        #expect(snapshot.nonTriedBytes == 5_767_168)
        #expect(snapshot.badBytes == 0)
        #expect(snapshot.rescuedBytes + snapshot.nonTriedBytes == deviceSize)
    }

    // REQ-0196
    @Test("REQ0196 extents outside the device are clipped and an empty domain is all non-tried")
    func REQ0196_clipsAndHandlesAnEmptyDomain() throws {
        let deviceSize: Int64 = 4_096
        let clipped = DdrescueDomainMapfile.render(
            domain: [
                ByteRange(position: 0, size: 1_024),
                ByteRange(position: 4_000, size: 1_000),
                ByteRange(position: -100, size: 50),
            ],
            deviceSize: deviceSize
        )
        let snapshot = try #require(DdrescueMapfile.parse(clipped))
        #expect(snapshot.extents == [
            MapfileExtent(position: 0, size: 1_024, status: "+"),
            MapfileExtent(position: 1_024, size: 2_976, status: "?"),
            MapfileExtent(position: 4_000, size: 96, status: "+"),
        ])

        let empty = DdrescueDomainMapfile.render(domain: [], deviceSize: deviceSize)
        let emptySnapshot = try #require(DdrescueMapfile.parse(empty))
        #expect(emptySnapshot.extents == [MapfileExtent(position: 0, size: 4_096, status: "?")])
        #expect(emptySnapshot.rescuedBytes == 0)
    }

    // REQ-0197
    @Test(
        "REQ0197 ddrescue -m copies only the extents marked + in the domain mapfile",
        .enabled(if: ddrescueExecutable() != nil, "ddrescue not available")
    )
    func REQ0197_liveDdrescueCopiesOnlyTheDomainExtents() throws {
        let ddrescue = try #require(ddrescueExecutable())
        let directory = URL(fileURLWithPath: try temp.makeDirectory("domain"))

        let deviceSize: Int64 = 8 * 1_048_576
        let source = directory.appendingPathComponent("src.bin")
        let destination = directory.appendingPathComponent("dst.bin")
        let domainMap = directory.appendingPathComponent("domain.map")
        let outMap = directory.appendingPathComponent("out.map")

        // A deterministic, never-zero pattern, so a zero in the destination is
        // proof that ddrescue did not read that byte.
        var bytes = Data(count: Int(deviceSize))
        bytes.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            for index in buffer.indices {
                buffer[index] = UInt8((index * 31 + 7) % 255 + 1)
            }
        }
        try bytes.write(to: source)

        let domain = [
            ByteRange(position: 0, size: 1_048_576),
            ByteRange(position: 3 * 1_048_576, size: 524_288),
        ]
        try DdrescueDomainMapfile.render(domain: domain, deviceSize: deviceSize)
            .write(to: domainMap, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ddrescue)
        process.arguments = [
            "-m", domainMap.path, source.path, destination.path, outMap.path,
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "ddrescue: \(stdout)\n\(stderr)")

        let copied = try Data(contentsOf: destination)
        // ddrescue stops at the end of the last finished block.
        #expect(copied.count == 3_670_016)
        #expect(copied[0..<1_048_576] == bytes[0..<1_048_576])
        #expect(copied[3_145_728..<3_670_016] == bytes[3_145_728..<3_670_016])
        #expect(copied[1_048_576..<3_145_728].allSatisfy { $0 == 0 }, "the gap was not read")

        let result = try #require(DdrescueMapfile.parse(
            String(contentsOf: outMap, encoding: .utf8)
        ))
        #expect(result.rescuedBytes == 1_572_864)
        #expect(result.nonTriedBytes == 6_815_744)
        #expect(result.rescuedBytes + result.nonTriedBytes == deviceSize)
    }

    // MARK: - 6. The real capture

    // REQ-0198
    @Test(
        "REQ0198 the real disk image's bitmap runs equal the recorded ntfscluster used runs",
        .enabled(if: diskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0198_realImageBitmapMatchesNtfscluster() throws {
        let parsed = try RealDisk.parse()
        let expected = try expectedUsedRuns()
        #expect(parsed.usedClusters == expected)
        #expect(parsed.usedClusters.reduce(0) { $0 + $1.count } == 12_308)

        let selection = try NTFSBootGeometry.select(
            primary: parsed.primaryBoot,
            backup: parsed.backupBoot
        ).get()
        #expect(selection.source == .primary)
        #expect(selection.geometry.mftRecordSize == 1024)
        #expect(selection.geometry.indexRecordSize == 4096)
    }

    // REQ-0199
    @Test(
        "REQ0199 the allocation domain covers every file data run ntfscluster reports",
        .enabled(if: diskImagePath() != nil, "run scripts/bootstrap.sh to build the NTFS fixtures")
    )
    func REQ0199_realImageDomainCoversEveryFileDataRun() throws {
        let parsed = try RealDisk.parse()
        let text = String(decoding: try fixtureDataCLI("ntfs-disk-ntfscluster.txt"), as: UTF8.self)
        let clusterMap = NTFSClusterOutputParser.parse(text)
        let fileRuns = clusterMap.runs.filter {
            if case .file = CopyRunOwnership.owner(of: $0) { return true }
            return false
        }
        #expect(!fileRuns.isEmpty, "the recorded output names file data runs")

        for run in fileRuns {
            let range = try #require(run.range)
            #expect(parsed.usedClusters.contains { $0.first <= range.first && $0.last >= range.last },
                    "\(run.path) \(range) is in the used clusters")
            let start = parsed.partitionOffset + range.first * Int64(parsed.geometry.clusterSize)
            let end = parsed.partitionOffset + (range.last + 1) * Int64(parsed.geometry.clusterSize)
            #expect(parsed.domain.used.contains { $0.position <= start && $0.end >= end },
                    "\(run.path) \(range) is inside the allocation domain")
        }

        #expect(parsed.domain.used.reduce(0) { $0 + $1.size } == 50_413_568)
        #expect(parsed.domain.free.reduce(0) { $0 + $1.size } == 16_695_296)
    }
}

// MARK: - The real image

/// Reads the few ranges the pure parsers need out of the gitignored spike
/// image. Nothing is written; no tool is run.
private enum RealDisk {
    struct Parsed {
        let partitionOffset: Int64
        let partitionLength: Int64
        let primaryBoot: Data
        let backupBoot: Data
        let geometry: NTFSBootGeometry
        let usedClusters: [ClusterRange]
        let domain: NTFSAllocationDomain
    }

    static func parse() throws -> Parsed {
        let path = try #require(diskImagePath())
        let mbr = try readRange(path, offset: 0, length: 512)
        let table = try #require(PartitionTableParser.parseMBR(mbr))
        let partition = try #require(table.ntfsCandidates.first)
        let partitionOffset = partition.byteOffset
        let partitionLength = partition.byteLength

        let primary = try readRange(path, offset: partitionOffset, length: 512)
        let backupOffset = try #require(NTFSBootSectorRules.backupOffset(
            partitionOffset: partitionOffset,
            partitionLengthBytes: partitionLength
        ))
        let backup = try readRange(path, offset: backupOffset, length: 512)
        let geometry = try NTFSBootGeometry.parse(primary).get()

        let recordZeroOffset = partitionOffset + geometry.mftOffset
        let mftRecord = try readRange(
            path, offset: recordZeroOffset, length: geometry.mftRecordSize
        )
        let mftData = try NTFSMFTRecord.dataAttribute(
            in: mftRecord,
            bytesPerSector: geometry.bytesPerSector,
            volumeClusters: geometry.totalClusters
        ).get()

        let recordSixOffset = try #require(mftByteOffset(
            record: 6,
            runs: mftData.runs,
            geometry: geometry,
            partitionOffset: partitionOffset
        ))
        let bitmapRecord = try readRange(
            path, offset: recordSixOffset, length: geometry.mftRecordSize
        )
        let bitmapData = try NTFSMFTRecord.dataAttribute(
            in: bitmapRecord,
            bytesPerSector: geometry.bytesPerSector,
            volumeClusters: geometry.totalClusters
        ).get()
        let bitmapBytes = try readAttributeData(
            path,
            attribute: bitmapData,
            geometry: geometry,
            partitionOffset: partitionOffset
        )

        let outcome = NTFSAllocation.evaluate(
            geometry: geometry,
            mftRecord: mftRecord,
            bitmapRecord: bitmapRecord,
            bitmapData: bitmapBytes,
            partitionOffset: partitionOffset,
            partitionLength: partitionLength
        )
        let domain = try #require(outcome.domain, "allocation: \(outcome)")

        return Parsed(
            partitionOffset: partitionOffset,
            partitionLength: partitionLength,
            primaryBoot: primary,
            backupBoot: backup,
            geometry: geometry,
            usedClusters: domain.usedClusters,
            domain: domain
        )
    }

    private static func mftByteOffset(
        record: Int,
        runs: [NTFSDataRun],
        geometry: NTFSBootGeometry,
        partitionOffset: Int64
    ) -> Int64? {
        let target = Int64(record) * Int64(geometry.mftRecordSize)
        let clusterSize = Int64(geometry.clusterSize)
        for run in runs {
            guard let lcn = run.lcn else { continue }
            let start = run.vcn * clusterSize
            let end = (run.vcn + run.clusterCount) * clusterSize
            guard target >= start, target < end else { continue }
            return partitionOffset + lcn * clusterSize + (target - start)
        }
        return nil
    }

    private static func readAttributeData(
        _ path: String,
        attribute: NTFSDataAttribute,
        geometry: NTFSBootGeometry,
        partitionOffset: Int64
    ) throws -> Data {
        if let resident = attribute.residentData { return resident }
        var data = Data()
        let clusterSize = Int64(geometry.clusterSize)
        for run in attribute.runs {
            guard let lcn = run.lcn else { continue }
            data.append(try readRange(
                path,
                offset: partitionOffset + lcn * clusterSize,
                length: Int(run.clusterCount * clusterSize)
            ))
        }
        return data.prefix(Int(attribute.dataSize))
    }

    private static func readRange(_ path: String, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }
}

// MARK: - Availability

private func diskImagePath() -> String? {
    TestFixtures.ntfsDiskImage()
}

private func ddrescueExecutable() -> String? {
    TestFixtures.ddrescueExecutable()
}

private func fixtureDataCLI(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: fixturePath(name)))
}

/// The recorded `ntfs-disk-used-runs.txt`, in volume-relative clusters.
private func expectedUsedRuns() throws -> [ClusterRange] {
    let text = String(decoding: try fixtureDataCLI("ntfs-disk-used-runs.txt"), as: UTF8.self)
    return try text.split(separator: "\n").compactMap { rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        let parts = line.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let first = Int64(parts[0]),
              let last = Int64(parts[1]),
              let range = ClusterRange(first: first, last: last)
        else { return nil }
        return range
    }
}
