import Foundation
import DiskTriageCore

// The allocation-aware order for `disktriage image` (diskdoctor.md §8,
// "Allocation-aware order for NTFS (default)"). Stage 0 reads metadata through
// ddrescue domain mapfiles, parses what is now in the image, and hands the
// pure library its bytes. No OS call or file read lives in DiskTriageCore.

// MARK: - Extent math

/// Sorts and coalesces touching or overlapping byte extents. The imager reads
/// bytes, not run boundaries.
func mergeExtents(_ extents: [ByteRange]) -> [ByteRange] {
    let sorted = extents.filter { $0.size > 0 }.sorted {
        $0.position == $1.position ? $0.size < $1.size : $0.position < $1.position
    }
    var merged: [ByteRange] = []
    for extent in sorted {
        if let last = merged.last, extent.position <= last.end {
            let end = max(last.end, extent.end)
            merged[merged.count - 1] = ByteRange(
                position: last.position,
                size: end - last.position
            )
        } else {
            merged.append(extent)
        }
    }
    return merged
}

/// Clips every extent to `[0, limit)`; an extent starting at or after the limit
/// is dropped. `--limit` composes with every stage, so no domain may reach past
/// it (REQ-0206).
func clipExtents(_ extents: [ByteRange], to limit: Int64) -> [ByteRange] {
    guard limit > 0 else { return [] }
    return mergeExtents(extents.compactMap { extent in
        let start = max(0, extent.position)
        let end = min(extent.end, limit)
        guard end > start else { return nil }
        return ByteRange(position: start, size: end - start)
    })
}

/// The bytes of `[0, limit)` not covered by `extents`.
func complementExtents(_ extents: [ByteRange], upTo limit: Int64) -> [ByteRange] {
    var result: [ByteRange] = []
    var cursor: Int64 = 0
    for extent in mergeExtents(extents) {
        if extent.position > cursor {
            result.append(ByteRange(position: cursor, size: extent.position - cursor))
        }
        cursor = max(cursor, extent.end)
    }
    if limit > cursor {
        result.append(ByteRange(position: cursor, size: limit - cursor))
    }
    return result
}

// MARK: - Scope accounting

/// The mapfile accounting inside one stage's scope. The progress line's
/// percentage is `rescuedBytes / totalBytes` for the current stage, not the
/// whole device (REQ-0212); the final summary's whole-device numbers stay as
/// they are.
struct ScopeAccounting: Equatable, Sendable {
    let totalBytes: Int64
    let rescuedBytes: Int64
    let failedBytes: Int64
    let failedExtents: Int
    let badBytes: Int64
    let badExtents: Int
    let remainingExtents: Int

    var remainingBytes: Int64 { max(0, totalBytes - rescuedBytes - badBytes) }

    var rescuedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(rescuedBytes) / Double(totalBytes)
    }
}

func scopeAccounting(snapshot: MapfileSnapshot, scope: [ByteRange]) -> ScopeAccounting {
    let ranges = mergeExtents(scope)
    let total = ranges.reduce(0) { $0 + $1.size }
    var rescued: Int64 = 0
    var failed: Int64 = 0
    var bad: Int64 = 0
    var failedExtents = 0
    var badExtents = 0
    var remainingExtents = 0

    for extent in snapshot.extents {
        let overlap = overlapBytes(extent, ranges)
        guard overlap > 0 else { continue }
        switch extent.status {
        case "+":
            rescued += overlap
        case "*", "/":
            failed += overlap
            failedExtents += 1
        case "-":
            bad += overlap
            badExtents += 1
        default:
            remainingExtents += 1
        }
    }

    return ScopeAccounting(
        totalBytes: total,
        rescuedBytes: rescued,
        failedBytes: failed,
        failedExtents: failedExtents,
        badBytes: bad,
        badExtents: badExtents,
        remainingExtents: remainingExtents
    )
}

private func overlapBytes(_ extent: MapfileExtent, _ ranges: [ByteRange]) -> Int64 {
    var total: Int64 = 0
    for range in ranges {
        let start = max(extent.position, range.position)
        let end = min(extent.end, range.end)
        if end > start { total += end - start }
    }
    return total
}

// MARK: - Stage 0

/// The data stage 0 recovered from the image, in device bytes.
struct Stage0Domain {
    let domain: NTFSAllocationDomain
    let geometrySource: BootSectorSource
    /// The geometry that supplied the cluster size and the cluster count, so
    /// the scope report prints the parsed values instead of re-deriving them.
    let geometry: NTFSBootGeometry
    /// The bytes the `$MFT`'s own physical data runs occupy (the volume
    /// metadata that is inside the used bytes).
    let mftBytes: Int64
    let partitionOffset: Int64
    let partitionLength: Int64
    /// Every extent stage 0 read, so the used-only scope can include the
    /// partition table and boot sectors that sit outside the used clusters.
    let readExtents: [ByteRange]
}

enum Stage0Outcome {
    case known(Stage0Domain)
    /// The layout was not NTFS, or the metadata did not parse. Fall back to
    /// whole-device passes, never to "free space is unneeded".
    case failed(String)
    /// The supervisor stopped the read (interrupt, device gone) or ddrescue
    /// could not be launched. The caller keeps the incomplete run.
    case stopped(PassResult)
}

struct Stage0Context {
    let deviceSize: Int64
    let imageBytes: Int64
    let rawDevice: String
    let image: String
    let mapfile: String
    let blockSize: Int64
    let timeoutSeconds: Int
    let limitBytes: Int64?
    let writeFile: (String, Data) throws -> Void
    let readImage: (String, Int64, Int) -> Data?
    /// Runs one ddrescue command; the scope is the extents it may read.
    let run: (DdrescuePass, [ByteRange]?) -> PassResult
    let progress: (String) -> Void
}

/// The stage-0 read/parse loop. Every read is a `ddrescue -m` run into the
/// main mapfile, followed by reading the bytes back out of the image and
/// parsing them with the pure library.
func runStage0(_ context: Stage0Context) -> Stage0Outcome {
    var readExtents: [ByteRange] = []
    let domainMapfile = context.image + ".domain-stage0.mapfile"
    let front = ByteRange(position: 0, size: min(1024, context.deviceSize))

    func read(_ name: String, _ extents: [ByteRange]) -> Stage0Outcome? {
        let clipped = clipExtents(extents, to: context.imageBytes)
        readExtents += clipped
        guard !clipped.isEmpty else { return nil }
        let text = DdrescueDomainMapfile.render(
            domain: clipped,
            deviceSize: context.deviceSize
        )
        do {
            try context.writeFile(domainMapfile, Data(text.utf8))
        } catch {
            return .failed("cannot write the stage-0 domain mapfile \(domainMapfile): "
                + error.localizedDescription)
        }
        let pass = DdrescuePass(
            pass: 0,
            argv: ddrescueStage0Command(
                rawDevice: context.rawDevice,
                image: context.image,
                mapfile: context.mapfile,
                domainMapfile: domainMapfile,
                blockSize: context.blockSize,
                timeoutSeconds: context.timeoutSeconds,
                limitBytes: context.limitBytes
            )
        )
        let result = context.run(pass, clipped)
        switch result.reason {
        case .complete:
            return nil
        case .launchFailed, .interrupted, .deviceDisappeared:
            return .stopped(result)
        case .stopRule, .stoppedOnItsOwn:
            // Bad metadata sectors are evidence, not a crash: read what is in
            // the image and let the parser decide whether it is usable.
            context.progress(
                "disktriage: stage 0 \(name): \(result.reason.rawValue)"
                    + (result.exitCode.map { ", exit \($0)" } ?? "")
                    + "; continuing with the image's bytes"
            )
            return nil
        }
    }

    func stop(_ outcome: Stage0Outcome?) -> Stage0Outcome? {
        if case .stopped = outcome { return outcome }
        if case .failed = outcome { return outcome }
        return nil
    }

    // 1. The partition table. LBA 0 is the MBR; LBA 1 is the GPT header when
    // the MBR is protective.
    if let outcome = stop(read("partition table", [front])) { return outcome }
    guard let mbr = context.readImage(context.image, 0, 512), mbr.count >= 512 else {
        return .failed("the partition table could not be read")
    }
    guard var table = PartitionTableParser.parseMBR(mbr) else {
        return .failed("no MBR/GPT partition table (the 55 AA signature is missing)")
    }

    if table.isProtective {
        guard let headerSector = context.readImage(context.image, 512, 512),
              let header = PartitionTableParser.parseGPTHeader(headerSector)
        else {
            return .failed("the protective MBR's GPT header is unreadable")
        }
        let planningTable = PartitionTable(
            scheme: .gpt,
            sectorSize: 512,
            partitions: table.partitions
        )
        let plan = NTFSStage0ReadPlan.plan(
            partitionOffset: 0,
            partitionLength: 0,
            partitionTable: planningTable,
            gptHeader: header,
            deviceSize: context.deviceSize
        )
        if let outcome = stop(read(
            "GPT header and entry array",
            plan.map(\.range)
        )) { return outcome }
        guard let entries = context.readImage(
            context.image, header.entryOffset, header.entryBytes
        ), let parsed = PartitionTableParser.parseGPTEntries(header, entries: entries) else {
            return .failed("the GPT entry array is unreadable")
        }
        table = parsed
    }

    guard let partition = table.ntfsCandidates.first else {
        return .failed("the partition table does not name an NTFS partition (no 0x07/basic-data entry)")
    }
    let partitionOffset = partition.byteOffset
    let partitionLength = partition.byteLength
    guard partitionLength >= 512 else {
        return .failed("the NTFS partition is shorter than one boot sector")
    }
    guard partitionOffset < context.imageBytes else {
        return .failed("the NTFS partition starts at \(partitionOffset) bytes, "
            + "beyond the \(context.imageBytes)-byte limit")
    }

    // 2. Both boot sectors. The backup is the partition's last sector, whose
    // offset comes from the partition table, never from the BPB.
    let bootPlan = NTFSStage0ReadPlan.plan(
        partitionOffset: partitionOffset,
        partitionLength: partitionLength
    )
    if let outcome = stop(read("boot sectors", bootPlan.map(\.range))) { return outcome }

    let primary = context.readImage(context.image, partitionOffset, 512)
        ?? Data(repeating: 0, count: 512)
    let backupOffset = NTFSBootSectorRules.backupOffset(
        partitionOffset: partitionOffset,
        partitionLengthBytes: partitionLength
    )
    let backup = backupOffset.flatMap { context.readImage(context.image, $0, 512) }
    let selection: NTFSBootGeometrySelection
    switch NTFSBootGeometry.select(primary: primary, backup: backup) {
    case .success(let value):
        selection = value
    case .failure(let failure):
        return .failed(describeBootFailure(failure))
    }
    let geometry = selection.geometry
    if selection.source == .backup {
        context.progress("disktriage: stage 0: the primary boot sector is invalid; "
            + "using the backup at \(backupOffset ?? -1)")
    }

    // 3. The first 16 MFT records. The region starts at the $MFT LCN from the
    // boot sector.
    let mftPlan = NTFSStage0ReadPlan.plan(
        partitionOffset: partitionOffset,
        partitionLength: partitionLength,
        geometry: geometry
    )
    let mftExtents = mftPlan.filter { $0.purpose == .mftRecords }.map(\.range)
    if let outcome = stop(read("$MFT records", mftExtents)) { return outcome }

    let mftRecordOffset = partitionOffset + geometry.mftOffset
    guard let mftRecord = context.readImage(
        context.image, mftRecordOffset, geometry.mftRecordSize
    ), mftRecord.count >= geometry.mftRecordSize else {
        return .failed("$MFT record 0 could not be read from the image")
    }
    let mftData: NTFSDataAttribute
    switch NTFSMFTRecord.dataAttribute(
        in: mftRecord,
        bytesPerSector: geometry.bytesPerSector,
        volumeClusters: geometry.totalClusters
    ) {
    case .success(let value): mftData = value
    case .failure(let failure):
        return .failed("$MFT record 0 did not parse: \(describeMFTFailure(failure))")
    }

    // Record 6 ($Bitmap). It is normally inside the first 16-record region;
    // a fragmented $MFT may put it elsewhere, so read exactly where the run
    // map says it is.
    guard let bitmapRecordOffset = mftRecordDeviceOffset(
        record: 6,
        runs: mftData.runs,
        geometry: geometry,
        partitionOffset: partitionOffset
    ) else {
        return .failed("$MFT record 6 ($Bitmap) is not inside any $MFT data run")
    }
    if let outcome = stop(read("$Bitmap record", [
        ByteRange(position: bitmapRecordOffset, size: Int64(geometry.mftRecordSize)),
    ])) { return outcome }
    guard let bitmapRecord = context.readImage(
        context.image, bitmapRecordOffset, geometry.mftRecordSize
    ), bitmapRecord.count >= geometry.mftRecordSize else {
        return .failed("$MFT record 6 ($Bitmap) could not be read from the image")
    }
    let bitmapAttribute: NTFSDataAttribute
    switch NTFSMFTRecord.dataAttribute(
        in: bitmapRecord,
        bytesPerSector: geometry.bytesPerSector,
        volumeClusters: geometry.totalClusters
    ) {
    case .success(let value): bitmapAttribute = value
    case .failure(let failure):
        return .failed("$Bitmap record 6 did not parse: \(describeMFTFailure(failure))")
    }

    // 4. The bitmap data itself, which can be several MB.
    var bitmapData: Data?
    if let resident = bitmapAttribute.residentData {
        bitmapData = resident
    } else {
        let clusterSize = Int64(geometry.clusterSize)
        let extents = bitmapAttribute.runs.compactMap { run -> ByteRange? in
            guard let lcn = run.lcn else { return nil }
            return ByteRange(
                position: partitionOffset + lcn * clusterSize,
                size: run.clusterCount * clusterSize
            )
        }
        if let outcome = stop(read("$Bitmap data", extents)) { return outcome }
        var bytes = Data()
        for extent in mergeExtents(extents) {
            let length = Int(min(extent.size, max(0, context.imageBytes - extent.position)))
            guard length > 0,
                  let chunk = context.readImage(context.image, extent.position, length)
            else { continue }
            bytes.append(chunk)
        }
        if Int64(bytes.count) < bitmapAttribute.dataSize {
            return .failed("$Bitmap data is short: \(bytes.count) of "
                + "\(bitmapAttribute.dataSize) bytes are in the image")
        }
        bitmapData = bytes.prefix(Int(bitmapAttribute.dataSize))
    }

    let outcome = NTFSAllocation.evaluate(
        geometry: geometry,
        mftRecord: mftRecord,
        bitmapRecord: bitmapRecord,
        bitmapData: bitmapData,
        partitionOffset: partitionOffset,
        partitionLength: partitionLength
    )
    switch outcome {
    case .known(let domain):
        let clusterBytes = Int64(geometry.clusterSize)
        let mftBytes = mftData.residentData.map { Int64($0.count) }
            ?? mftData.runs.reduce(0) { total, run in
                run.isSparse ? total : total + run.clusterCount * clusterBytes
            }
        return .known(Stage0Domain(
            domain: domain,
            geometrySource: selection.source,
            geometry: geometry,
            mftBytes: mftBytes,
            partitionOffset: partitionOffset,
            partitionLength: partitionLength,
            readExtents: mergeExtents(readExtents)
        ))
    case .unknown(let failure):
        return .failed(describeAllocationFailure(failure))
    }
}

/// Volume-relative MFT record → device byte offset, following the $MFT run
/// map. `nil` when the record is not inside a physical run.
func mftRecordDeviceOffset(
    record: Int,
    runs: [NTFSDataRun],
    geometry: NTFSBootGeometry,
    partitionOffset: Int64
) -> Int64? {
    let target = Int64(record) * Int64(geometry.mftRecordSize)
    let clusterSize = Int64(geometry.clusterSize)
    for run in runs {
        let start = run.vcn * clusterSize
        let end = (run.vcn + run.clusterCount) * clusterSize
        guard target >= start, target < end, let lcn = run.lcn else { continue }
        return partitionOffset + lcn * clusterSize + (target - start)
    }
    return nil
}

// MARK: - Stage-0 failure text

func describeBootFailure(_ failure: NTFSBootGeometrySelectionFailure) -> String {
    switch failure {
    case .noUsableBootSector(let primary, let backup):
        let backupText = backup.map(describeGeometryFailure) ?? "no backup sector was readable"
        return "both boot sectors are unusable (primary: \(describeGeometryFailure(primary)); "
            + "backup: \(backupText))"
    }
}

func describeGeometryFailure(_ failure: NTFSBootGeometryFailure) -> String {
    switch failure {
    case .invalidBootSector(let value): return value.message
    case .invalidMFTRecordSize(let raw): return "MFT record size \(raw) is not a valid encoding"
    case .invalidIndexRecordSize(let raw): return "index record size \(raw) is not a valid encoding"
    case .mftOutsideVolume(let lcn, let clusters):
        return "$MFT LCN \(lcn) is outside the \(clusters)-cluster volume"
    }
}

func describeMFTFailure(_ failure: NTFSMFTRecordFailure) -> String {
    switch failure {
    case .tooShort(let count): return "the record is \(count) bytes, shorter than an MFT record"
    case .badMagic: return "the FILE magic is missing"
    case .recordNotSectorAligned(let bytes, let sector):
        return "\(bytes) bytes is not a multiple of the \(sector)-byte sector"
    case .badUpdateSequenceArray(let offset, let count):
        return "the update sequence array at \(offset) has \(count) entries"
    case .fixupMismatch(let sector, let expected, let found):
        return "sector \(sector) is torn (USN \(expected), found \(found))"
    case .truncatedAttribute(let offset): return "an attribute at \(offset) is truncated"
    case .attributeListUnsupported:
        return "an $ATTRIBUTE_LIST is present and following extension records is not supported"
    case .dataAttributeMissing: return "no unnamed $DATA attribute"
    case .multipleDataAttributes: return "more than one unnamed $DATA attribute"
    case .invalidDataSize: return "the $DATA size is not valid"
    case .invalidRunList(let value): return "the run list is invalid (\(value))"
    }
}

func describeAllocationFailure(_ failure: NTFSAllocationFailure) -> String {
    switch failure {
    case .mftRecord(let value): return "$MFT record 0: \(describeMFTFailure(value))"
    case .bitmapRecord(let value): return "$Bitmap record 6: \(describeMFTFailure(value))"
    case .bitmapDataNotRead: return "the $Bitmap data was not read"
    case .bitmap(.emptyVolume): return "the volume has no clusters"
    case .bitmap(.bitmapTooShort(let expected, let actual)):
        return "$Bitmap is short: \(actual) of \(expected) bytes"
    case .mftOutsidePartition(let offset, let length):
        return "$MFT at \(offset) is outside the \(length)-byte partition"
    case .partitionOverflow: return "the partition end overflows a 64-bit offset"
    case .mftClustersNotMarkedUsed(let cluster):
        return "the $Bitmap does not mark the $MFT's own cluster \(cluster) used"
    }
}

// MARK: - The dry-run plan

/// The stage commands the dry run prints before any read. The command shapes
/// are exact; the extent content of a stage domain mapfile cannot be known
/// before the bitmap is parsed, which the note says (REQ-0209).
struct PlannedStage: Equatable, Sendable {
    let stage: Int
    let name: String
    let lines: [String]
    let note: String?
}

func plannedStages(
    rawDevice: String,
    image: String,
    mapfile: String,
    blockSize: Int64,
    limitBytes: Int64?,
    minReadRateBytesPerSecond: Int64?,
    usedOnly: Bool
) -> [PlannedStage] {
    let stage0Mapfile = image + ".domain-stage0.mapfile"
    let stage1Mapfile = image + ".domain-stage1.mapfile"
    let stage2Mapfile = image + ".domain-stage2.mapfile"

    let stage0 = ddrescueStage0Command(
        rawDevice: rawDevice,
        image: image,
        mapfile: mapfile,
        domainMapfile: stage0Mapfile,
        blockSize: blockSize,
        limitBytes: limitBytes
    )
    let stage1 = ddrescueStagePasses(
        rawDevice: rawDevice,
        image: image,
        mapfile: mapfile,
        domainMapfile: stage1Mapfile,
        blockSize: blockSize,
        stage: 1,
        limitBytes: limitBytes,
        minReadRateBytesPerSecond: minReadRateBytesPerSecond
    )
    let stage2 = ddrescueStagePasses(
        rawDevice: rawDevice,
        image: image,
        mapfile: mapfile,
        domainMapfile: stage2Mapfile,
        blockSize: blockSize,
        stage: 2,
        limitBytes: limitBytes,
        minReadRateBytesPerSecond: minReadRateBytesPerSecond
    )

    return [
        PlannedStage(
            stage: 0,
            name: "metadata",
            lines: [stage0.joined(separator: " ")],
            note: "partition table, primary and backup boot sectors, $MFT records 0-15, $Bitmap data"
        ),
        PlannedStage(
            stage: 1,
            name: "used clusters + metadata",
            lines: stage1.map(\.line),
            note: "domain computed from the bitmap"
        ),
        PlannedStage(
            stage: 2,
            name: "rest of the device",
            lines: usedOnly ? [] : stage2.map(\.line),
            note: usedOnly
                ? "skipped by --used-only"
                : "domain computed from the bitmap: the complement of stage 1"
        ),
    ]
}
