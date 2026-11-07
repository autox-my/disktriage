import Foundation
import Testing
import DiskTriageCore

/// The pure NTFS allocation-domain library: boot geometry, the stage-0 read
/// plan, MFT records with USA fixups and data runs, the $Bitmap, the allocation
/// domain and its free complement.
///
/// Expectations come from `diskdoctor.md` §8, from the recorded hand-built
/// bytes in `Tests/Fixtures/ntfs-disk-*` and from the ntfs-3g output recorded in
/// `Tests/Fixtures/ntfs-disk-notes.md` — never recomputed by the code under
/// test.
struct NTFSAllocationTests {

    // MARK: - 1. Boot geometry

    // REQ-0185
    @Test("REQ0185 parses the spike image's boot geometry, including signed record sizes")
    func REQ0185_parsesTheRealDiskGeometry() throws {
        let sector = try fixtureData("ntfs-disk-boot-primary.bin")
        let geometry = try NTFSBootGeometry.parse(sector).get()

        #expect(geometry.bytesPerSector == 512)
        #expect(geometry.sectorsPerCluster == 8)
        #expect(geometry.clusterSize == 4096)
        #expect(geometry.totalSectors == 131_071)
        #expect(geometry.totalClusters == 16_383)
        #expect(geometry.mftLCN == 4)
        #expect(geometry.mftMirrorLCN == 8191)
        #expect(geometry.mftRecordSize == 1024)
        #expect(geometry.indexRecordSize == 4096)
        #expect(geometry.mftOffset == 16_384)
        #expect(geometry.volumeBytes == 67_108_352)
    }

    // REQ-0185
    @Test("REQ0185 a negative clusters-per-record byte is 2^-n bytes, a positive one is clusters")
    func REQ0185_decodesSignedAndPositiveRecordSizes() throws {
        let negative = B.bootSector(clustersPerMFTRecord: -9, clustersPerIndexRecord: -12)
        let small = try NTFSBootGeometry.parse(Data(negative)).get()
        #expect(small.mftRecordSize == 512)
        #expect(small.indexRecordSize == 4096)

        let positive = B.bootSector(clustersPerMFTRecord: 2, clustersPerIndexRecord: 1)
        let clustered = try NTFSBootGeometry.parse(Data(positive)).get()
        #expect(clustered.mftRecordSize == 8192)
        #expect(clustered.indexRecordSize == 4096)
    }

    // REQ-0186
    @Test("REQ0186 every invalid boot field is a typed geometry failure")
    func REQ0186_rejectsInvalidGeometryWithTypedFailures() {
        var wrongOEM = B.bootSector()
        wrongOEM[3] = 0x58
        #expect(NTFSBootGeometry.parse(Data(wrongOEM)) == .failure(.invalidBootSector(.badOEMID)))

        var wrongSector = B.bootSector()
        wrongSector[0x0B] = 0x00
        wrongSector[0x0C] = 0x03
        #expect(NTFSBootGeometry.parse(Data(wrongSector))
            == .failure(.invalidBootSector(.unsupportedBytesPerSector(768))))

        var wrongCluster = B.bootSector(sectorsPerCluster: 3)
        wrongCluster[0x0D] = 3
        #expect(NTFSBootGeometry.parse(Data(wrongCluster))
            == .failure(.invalidBootSector(.invalidSectorsPerCluster(3))))

        var noSignature = B.bootSector()
        noSignature[510] = 0
        #expect(NTFSBootGeometry.parse(Data(noSignature))
            == .failure(.invalidBootSector(.missingBootSignature)))

        var zeroRecord = B.bootSector(clustersPerMFTRecord: 0)
        zeroRecord[0x40] = 0
        #expect(NTFSBootGeometry.parse(Data(zeroRecord)) == .failure(.invalidMFTRecordSize(0)))

        let outside = B.bootSector(totalSectors: 131_071, mftLCN: 20_000)
        #expect(NTFSBootGeometry.parse(Data(outside))
            == .failure(.mftOutsideVolume(lcn: 20_000, clusters: 16_383)))
    }

    // REQ-0186
    @Test("REQ0186 an MFT LCN at or past the volume end is not a usable geometry")
    func REQ0186_mftMustLieInsideTheVolume() throws {
        let lastCluster = B.bootSector(
            totalSectors: 131_071,
            mftLCN: 16_383
        )
        #expect(NTFSBootGeometry.parse(Data(lastCluster))
            == .failure(.mftOutsideVolume(lcn: 16_383, clusters: 16_383)))
    }

    // MARK: - 1b. Primary or backup boot sector

    // REQ-0187
    @Test("REQ0187 an invalid primary uses the backup geometry and reports that source")
    func REQ0187_fallsBackToTheBackupBootSector() throws {
        var primary = try fixtureData("ntfs-disk-boot-primary.bin")
        primary[3] = 0x58 // "XTFS    "
        let backup = try fixtureData("ntfs-disk-boot-backup.bin")

        let selection = try NTFSBootGeometry.select(primary: primary, backup: backup).get()
        #expect(selection.source == .backup)
        #expect(selection.geometry.mftLCN == 4)
        #expect(selection.primaryFailure == .invalidBootSector(.badOEMID))
    }

    // REQ-0187
    @Test("REQ0187 a valid primary wins; two bad sectors are a typed failure")
    func REQ0187_prefersThePrimaryAndRejectsTwoBadSectors() throws {
        let primary = try fixtureData("ntfs-disk-boot-primary.bin")
        let backup = try fixtureData("ntfs-disk-boot-backup.bin")

        let selection = try NTFSBootGeometry.select(primary: primary, backup: backup).get()
        #expect(selection.source == .primary)
        #expect(selection.primaryFailure == nil)

        var badPrimary = primary
        badPrimary[3] = 0x58
        var badBackup = backup
        badBackup[510] = 0

        #expect(NTFSBootGeometry.select(primary: badPrimary, backup: badBackup)
            == .failure(.noUsableBootSector(
                primary: .invalidBootSector(.badOEMID),
                backup: .invalidBootSector(.missingBootSignature)
            )))
        #expect(NTFSBootGeometry.select(primary: badPrimary, backup: nil)
            == .failure(.noUsableBootSector(primary: .invalidBootSector(.badOEMID), backup: nil)))
    }

    // MARK: - 2. Stage-0 read plan

    // REQ-0188
    @Test("REQ0188 stage A reads the table and both boot sectors; stage B adds the first MFT records")
    func REQ0188_stage0PlanIsOrderedAndHasTwoSteps() throws {
        let partitionOffset: Int64 = 1_048_576
        let partitionLength: Int64 = 67_108_864
        let table = PartitionTable(
            scheme: .mbr,
            sectorSize: 512,
            partitions: [DiskPartition(
                index: 1, mbrType: 0x07, typeGUID: nil,
                startLBA: 2048, sectorCount: 131_072, sectorSize: 512
            )]
        )

        let stepA = NTFSStage0ReadPlan.plan(
            partitionOffset: partitionOffset,
            partitionLength: partitionLength,
            partitionTable: table,
            deviceSize: 83_886_080
        )
        #expect(stepA.map(\.purpose) == [.partitionTable, .primaryBootSector, .backupBootSector])
        #expect(stepA.map(\.position) == [0, 1_048_576, 68_156_928])
        #expect(stepA.allSatisfy { $0.size == 512 })

        let geometry = try NTFSBootGeometry.parse(fixtureData("ntfs-disk-boot-primary.bin")).get()
        let stepB = NTFSStage0ReadPlan.plan(
            partitionOffset: partitionOffset,
            partitionLength: partitionLength,
            geometry: geometry,
            partitionTable: table,
            deviceSize: 83_886_080
        )
        #expect(stepB.map(\.purpose) == [
            .partitionTable, .primaryBootSector, .backupBootSector, .mftRecords,
        ])
        #expect(stepB.last?.position == 1_064_960)   // partition + MFT LCN 4 × 4096
        #expect(stepB.last?.size == 16_384)          // 16 MFT records × 1024
    }

    // REQ-0188
    @Test("REQ0188 a GPT plan includes the primary and backup header and entry array")
    func REQ0188_gptPlanIncludesTheBackupHeader() {
        let table = PartitionTable(
            scheme: .gpt,
            sectorSize: 512,
            partitions: [DiskPartition(
                index: 1, mbrType: nil, typeGUID: PartitionTableParser.microsoftBasicDataGUID,
                startLBA: 2048, sectorCount: 131_072, sectorSize: 512
            )]
        )
        let gpt = GPTHeaderLocation(entriesLBA: 2, entryCount: 128, entrySize: 128, sectorSize: 512)
        let plan = NTFSStage0ReadPlan.plan(
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864,
            partitionTable: table,
            gptHeader: gpt,
            deviceSize: 83_886_080
        )

        #expect(plan.map(\.purpose) == [
            .partitionTable, .gptHeader, .gptEntries,
            .gptBackupHeader, .gptBackupEntries,
            .primaryBootSector, .backupBootSector,
        ])
        #expect(plan[1].position == 512)
        #expect(plan[2].position == 1024)
        #expect(plan[2].size == 16_384)
        #expect(plan[3].position == 83_885_568)      // deviceSize - 512
        #expect(plan[4].position == 83_869_184)      // backup header - entry bytes
    }

    // MARK: - 3. MFT records

    // REQ-0189
    @Test("REQ0189 the update sequence array is applied and a torn record is rejected")
    func REQ0189_appliesFixupsAndRejectsTornRecords() throws {
        let record = try fixtureData("ntfs-disk-mft-record-0.bin")
        let fixed = try NTFSMFTRecord.applyFixups(record, bytesPerSector: 512).get()
        #expect(fixed.count == 1024)
        // The real USN is 0x0037; its two sector tails are restored to zero.
        #expect(fixed[510] == 0 && fixed[511] == 0)
        #expect(fixed[1022] == 0 && fixed[1023] == 0)

        var torn = record
        torn[510] = 0xAA
        #expect(NTFSMFTRecord.applyFixups(torn, bytesPerSector: 512)
            == .failure(.fixupMismatch(sector: 0, expected: 0x0037, found: 0x00AA)))

        #expect(NTFSMFTRecord.applyFixups(Data(repeating: 0, count: 1024), bytesPerSector: 512)
            == .failure(.badMagic))
    }

    // REQ-0190
    @Test("REQ0190 record 0 and record 6 decode their non-resident $DATA run lists")
    func REQ0190_decodesMFTAndBitmapDataAttributes() throws {
        let mft = try NTFSMFTRecord.dataAttribute(
            in: fixtureData("ntfs-disk-mft-record-0.bin"),
            bytesPerSector: 512,
            volumeClusters: 16_383
        ).get()
        #expect(!mft.isResident)
        #expect(mft.residentData == nil)
        #expect(mft.dataSize == 119_808)   // 0x1d400: 117 records × 1024
        #expect(mft.runs == [NTFSDataRun(vcn: 0, clusterCount: 31, lcn: 4)])

        let bitmap = try NTFSMFTRecord.dataAttribute(
            in: fixtureData("ntfs-disk-mft-record-6.bin"),
            bytesPerSector: 512,
            volumeClusters: 16_383
        ).get()
        #expect(bitmap.dataSize == 2048)
        #expect(bitmap.runs == [NTFSDataRun(vcn: 0, clusterCount: 1, lcn: 2055)])
    }

    // REQ-0190
    @Test("REQ0190 a resident $DATA is bytes, not a run list")
    func REQ0190_decodesAResidentDataAttribute() throws {
        let attribute = B.residentDataAttribute([0xDE, 0xAD, 0xBE, 0xEF])
        let record = B.record(attributes: [attribute])
        let data = try NTFSMFTRecord.dataAttribute(in: record, bytesPerSector: 512).get()
        #expect(data.isResident)
        #expect(data.residentData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(data.runs.isEmpty)
        #expect(data.dataSize == 4)
    }

    // REQ-0190
    @Test("REQ0190 mapping pairs are signed deltas, and a missing offset is a sparse run")
    func REQ0190_decodesSignedDeltasAndSparseRuns() throws {
        // run 1: 10 clusters at LCN 100; run 2: 5 clusters at 100-50 = 50;
        // run 3: 3 sparse clusters; terminator.
        let runList = Data([0x11, 0x0A, 0x64, 0x11, 0x05, 0xCE, 0x01, 0x03, 0x00])
        let runs = try NTFSRunList.decode(runList, volumeClusters: 1000).get()
        #expect(runs == [
            NTFSDataRun(vcn: 0, clusterCount: 10, lcn: 100),
            NTFSDataRun(vcn: 10, clusterCount: 5, lcn: 50),
            NTFSDataRun(vcn: 15, clusterCount: 3, lcn: nil),
        ])
    }

    // REQ-0191
    @Test("REQ0191 an $ATTRIBUTE_LIST is reported as unsupported, never guessed")
    func REQ0191_reportsAttributeListAsUnsupported() {
        let record = B.record(attributes: [B.attributeList()])
        #expect(NTFSMFTRecord.dataAttribute(in: record, bytesPerSector: 512)
            == .failure(.attributeListUnsupported))
    }

    // MARK: - 4. $Bitmap and the allocation domain

    // REQ-0192
    @Test("REQ0192 the real bitmap produces the ntfscluster used runs, ignoring the tail bit")
    func REQ0192_bitmapUsedRunsMatchTheRecordedToolOutput() throws {
        let bitmap = try fixtureData("ntfs-disk-bitmap.bin")
        let used = try NTFSBitmap.usedClusters(bitmap, totalClusters: 16_383).get()
        let expected = try Fixtures.usedRuns()

        #expect(used == expected)
        #expect(used.reduce(0) { $0 + $1.count } == 12_308)
        #expect(used.first?.first == 0)
        #expect(used.last?.last == 16_382)
    }

    // REQ-0192
    @Test("REQ0192 bits are LSB-first within each byte")
    func REQ0192_readsBitsLeastSignificantFirst() throws {
        let used = try NTFSBitmap.usedClusters(Data([0b0000_0101]), totalClusters: 8).get()
        #expect(used == [try #require(ClusterRange(first: 0, last: 0)),
                         try #require(ClusterRange(first: 2, last: 2))])
    }

    // REQ-0192
    @Test("REQ0192 bits past the volume end are ignored, not counted as used")
    func REQ0192_ignoresTailBitsPastTheVolume() throws {
        let used = try NTFSBitmap.usedClusters(Data([0xFF, 0xFF]), totalClusters: 10).get()
        #expect(used == [try #require(ClusterRange(first: 0, last: 9))])
    }

    // REQ-0193
    @Test("REQ0193 a short bitmap is a typed failure, not an empty bitmap")
    func REQ0193_rejectsABitmapShorterThanTheVolume() {
        #expect(NTFSBitmap.usedClusters(Data(repeating: 0, count: 12), totalClusters: 100)
            == .failure(.bitmapTooShort(expected: 13, actual: 12)))
    }

    // REQ-0193
    @Test("REQ0193 a fragmented, overlapping or past-end run list is a typed failure")
    func REQ0193_rejectsBadBitmapRunLists() {
        // Three runs with maxRuns 2.
        let fragmented = Data([0x11, 0x01, 0x00, 0x11, 0x01, 0x01, 0x11, 0x01, 0x02, 0x00])
        #expect(NTFSRunList.decode(fragmented, volumeClusters: 100, maxRuns: 2)
            == .failure(.tooManyRuns(2)))

        // LCN 10-11 then LCN 11-12 overlap.
        let overlapping = Data([0x11, 0x02, 0x0A, 0x11, 0x02, 0x01, 0x00])
        #expect(NTFSRunList.decode(overlapping, volumeClusters: 100)
            == .failure(.overlappingLCNs))

        // LCN 10-11 in an 11-cluster volume: cluster 11 is past the end.
        let pastEnd = Data([0x11, 0x02, 0x0A, 0x00])
        #expect(NTFSRunList.decode(pastEnd, volumeClusters: 11)
            == .failure(.runPastVolumeEnd(lcn: 10, count: 2, volumeClusters: 11)))
    }

    // REQ-0194
    @Test("REQ0194 the domain is the used union in device bytes, with a free complement")
    func REQ0194_buildsTheDeviceDomainAndFreeComplement() throws {
        let geometry = try NTFSBootGeometry.parse(fixtureData("ntfs-disk-boot-primary.bin")).get()
        let mft = try NTFSMFTRecord.dataAttribute(
            in: fixtureData("ntfs-disk-mft-record-0.bin"),
            bytesPerSector: 512,
            volumeClusters: geometry.totalClusters
        ).get()
        let usedClusters = try NTFSBitmap.usedClusters(
            fixtureData("ntfs-disk-bitmap.bin"),
            totalClusters: geometry.totalClusters
        ).get()

        let domain = try NTFSAllocation.allocationDomain(
            geometry: geometry,
            mftRuns: mft.runs,
            usedClusters: usedClusters,
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864
        ).get()

        #expect(domain.used.count == 10)
        #expect(domain.used.first == ByteRange(position: 1_048_576, size: 12_288))
        #expect(domain.used.last == ByteRange(position: 67_674_112, size: 479_232))
        #expect(domain.used.last?.end == 68_153_344)
        #expect(domain.used.reduce(0) { $0 + $1.size } == 50_413_568)
        #expect(domain.free.reduce(0) { $0 + $1.size } == 16_695_296)
        #expect(domain.used.reduce(0) { $0 + $1.size }
            + domain.free.reduce(0) { $0 + $1.size } == 67_108_864)
        #expect(domain.free.first == ByteRange(position: 1_060_864, size: 4096))
        #expect(domain.usedClusters == usedClusters)
        #expect(domain.metadataRecords == ByteRange(position: 1_064_960, size: 16_384))
    }

    // REQ-0194
    @Test("REQ0194 adjacent extents are merged, not returned as touching runs")
    func REQ0194_mergesAdjacentAndOverlappingExtents() throws {
        let geometry = try NTFSBootGeometry.parse(Data(B.bootSector())).get()
        let runs = [
            try #require(ClusterRange(first: 4, last: 5)),
            try #require(ClusterRange(first: 5, last: 6)),
            try #require(ClusterRange(first: 6, last: 7)),
        ]
        let domain = try NTFSAllocation.allocationDomain(
            geometry: geometry,
            mftRuns: [NTFSDataRun(vcn: 0, clusterCount: 2, lcn: 4)],
            usedClusters: runs,
            partitionOffset: 0,
            partitionLength: geometry.volumeBytes
        ).get()

        #expect(domain.used == [ByteRange(position: 16_384, size: 16_384)])
        #expect(domain.metadataRecords == ByteRange(position: 16_384, size: 16_384))
    }

    // REQ-0195
    @Test("REQ0195 an unread bitmap is an unknown allocation, never everything free")
    func REQ0195_unknownAllocationHasNoFreeExtents() throws {
        let geometry = try NTFSBootGeometry.parse(fixtureData("ntfs-disk-boot-primary.bin")).get()
        let mftRecord = try fixtureData("ntfs-disk-mft-record-0.bin")
        let bitmapRecord = try fixtureData("ntfs-disk-mft-record-6.bin")

        let unread = NTFSAllocation.evaluate(
            geometry: geometry,
            mftRecord: mftRecord,
            bitmapRecord: bitmapRecord,
            bitmapData: nil,
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864
        )
        #expect(unread == .unknown(.bitmapDataNotRead))
        #expect(unread.domain == nil)

        let short = NTFSAllocation.evaluate(
            geometry: geometry,
            mftRecord: mftRecord,
            bitmapRecord: bitmapRecord,
            bitmapData: Data(repeating: 0, count: 12),
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864
        )
        #expect(short == .unknown(.bitmap(.bitmapTooShort(expected: 2048, actual: 12))))
        #expect(short.domain == nil)

        var tornMFT = mftRecord
        tornMFT[510] = 0xAA
        let torn = NTFSAllocation.evaluate(
            geometry: geometry,
            mftRecord: tornMFT,
            bitmapRecord: bitmapRecord,
            bitmapData: try fixtureData("ntfs-disk-bitmap.bin"),
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864
        )
        #expect(torn == .unknown(.mftRecord(.fixupMismatch(
            sector: 0, expected: 0x0037, found: 0x00AA
        ))))
        #expect(torn.domain == nil)
    }

    // REQ-0195
    @Test("REQ0195 an MFT outside the partition is a typed failure, not a zero-length domain")
    func REQ0195_rejectsAnMFTOutsideThePartition() throws {
        let geometry = try NTFSBootGeometry.parse(fixtureData("ntfs-disk-boot-primary.bin")).get()
        let used = try NTFSBitmap.usedClusters(
            fixtureData("ntfs-disk-bitmap.bin"),
            totalClusters: geometry.totalClusters
        ).get()

        #expect(NTFSAllocation.allocationDomain(
            geometry: geometry,
            mftRuns: [NTFSDataRun(vcn: 0, clusterCount: 31, lcn: 4)],
            usedClusters: used,
            partitionOffset: 0,
            partitionLength: 4096
        ) == .failure(.mftOutsidePartition(mftOffset: 16_384, partitionLength: 4096)))
    }

    // REQ-0210
    @Test("REQ0210 a $Bitmap that does not mark the $MFT's own clusters used is not trusted")
    func REQ0210_bitmapMustMarkTheMFTRunsUsed() throws {
        let geometry = try NTFSBootGeometry.parse(fixtureData("ntfs-disk-boot-primary.bin")).get()
        let mft = try NTFSMFTRecord.dataAttribute(
            in: fixtureData("ntfs-disk-mft-record-0.bin"),
            bytesPerSector: 512,
            volumeClusters: geometry.totalClusters
        ).get()

        // A zeroed $Bitmap parses as "nothing is used", including the MFT and
        // the metadata the parser just read. That is a corrupt bitmap, not a
        // licence to skip every cluster as free.
        #expect(NTFSAllocation.allocationDomain(
            geometry: geometry,
            mftRuns: mft.runs,
            usedClusters: [],
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864
        ) == .failure(.mftClustersNotMarkedUsed(cluster: 4)))

        let used = try NTFSBitmap.usedClusters(
            fixtureData("ntfs-disk-bitmap.bin"),
            totalClusters: geometry.totalClusters
        ).get()
        #expect((try? NTFSAllocation.allocationDomain(
            geometry: geometry,
            mftRuns: mft.runs,
            usedClusters: used,
            partitionOffset: 1_048_576,
            partitionLength: 67_108_864
        ).get()) != nil, "the real bitmap marks the MFT clusters used")
    }
}

// MARK: - Fixtures and hand-built bytes

private enum Fixtures {
    /// The recorded `ntfs-disk-used-runs.txt`, in volume-relative clusters.
    static func usedRuns() throws -> [ClusterRange] {
        let data = try fixtureData("ntfs-disk-used-runs.txt")
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let first = Int64(parts[0]),
                  let last = Int64(parts[1])
            else { throw FixtureError.badRun(line) }
            guard let range = ClusterRange(first: first, last: last) else {
                throw FixtureError.badRun(line)
            }
            return range
        }
    }

    enum FixtureError: Error { case badRun(String) }
}

private enum B {
    static func bootSector(
        bytesPerSector: UInt16 = 512,
        sectorsPerCluster: UInt8 = 8,
        totalSectors: UInt64 = 131_071,
        mftLCN: UInt64 = 4,
        mftMirrorLCN: UInt64 = 8191,
        clustersPerMFTRecord: Int8 = -10,
        clustersPerIndexRecord: Int8 = 1
    ) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: 512)
        sector.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        sector.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        sector[0x0B] = UInt8(bytesPerSector & 0xFF)
        sector[0x0C] = UInt8(bytesPerSector >> 8)
        sector[0x0D] = sectorsPerCluster
        putLE64(&sector, at: 0x28, value: totalSectors)
        putLE64(&sector, at: 0x30, value: mftLCN)
        putLE64(&sector, at: 0x38, value: mftMirrorLCN)
        sector[0x40] = UInt8(bitPattern: clustersPerMFTRecord)
        sector[0x44] = UInt8(bitPattern: clustersPerIndexRecord)
        sector[510] = 0x55
        sector[511] = 0xAA
        return sector
    }

    static func record(attributes: [[UInt8]]) -> Data {
        var record = [UInt8](repeating: 0, count: 1024)
        record.replaceSubrange(0..<4, with: Array("FILE".utf8))
        putLE16(&record, at: 0x04, value: 0x0030)   // USA offset
        putLE16(&record, at: 0x06, value: 3)        // USN + two sector tails
        putLE16(&record, at: 0x14, value: 0x0038)   // first attribute
        putLE16(&record, at: 0x30, value: 0x0001)   // USN
        record[510] = 0x01
        record[511] = 0x00
        record[1022] = 0x01
        record[1023] = 0x00

        var offset = 0x38
        for attribute in attributes {
            record.replaceSubrange(offset..<(offset + attribute.count), with: attribute)
            offset += attribute.count
        }
        putLE32(&record, at: offset, value: 0xFFFF_FFFF)
        putLE32(&record, at: 0x18, value: UInt32(offset + 4))
        return Data(record)
    }

    static func residentDataAttribute(_ value: [UInt8]) -> [UInt8] {
        let length = align8(24 + value.count)
        var attribute = [UInt8](repeating: 0, count: length)
        putLE32(&attribute, at: 0, value: 0x80)
        putLE32(&attribute, at: 4, value: UInt32(length))
        attribute[8] = 0
        putLE16(&attribute, at: 0x14, value: 24)    // value offset
        putLE32(&attribute, at: 0x10, value: UInt32(value.count))
        attribute.replaceSubrange(24..<(24 + value.count), with: value)
        return attribute
    }

    static func attributeList() -> [UInt8] {
        var attribute = [UInt8](repeating: 0, count: 32)
        putLE32(&attribute, at: 0, value: 0x20)
        putLE32(&attribute, at: 4, value: 32)
        return attribute
    }

    static func align8(_ value: Int) -> Int { (value + 7) & ~7 }

    static func putLE16(_ bytes: inout [UInt8], at offset: Int, value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    static func putLE32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }

    static func putLE64(_ bytes: inout [UInt8], at offset: Int, value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }
}
