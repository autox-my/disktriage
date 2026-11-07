import Foundation

public enum NTFSBitmapFailure: Error, Equatable, Sendable {
    /// The volume has no clusters, so there is nothing a bitmap could describe.
    case emptyVolume
    case bitmapTooShort(expected: Int, actual: Int)
}

/// The `$Bitmap` decoder. NTFS numbers bits **least-significant first** inside
/// each byte (cluster 0 is bit 0 of byte 0). Bits at or past the volume's
/// cluster count are `$Bitmap` padding and are ignored, never counted as used.
public enum NTFSBitmap {
    public static func usedClusters(
        _ bytes: Data,
        totalClusters: Int64
    ) -> Result<[ClusterRange], NTFSBitmapFailure> {
        guard totalClusters > 0 else { return .failure(.emptyVolume) }
        let expected = Int((totalClusters + 7) / 8)
        guard bytes.count >= expected else {
            return .failure(.bitmapTooShort(expected: expected, actual: bytes.count))
        }

        var runs: [ClusterRange] = []
        var runStart: Int64?
        for cluster in 0..<totalClusters {
            let byte = bytes[Int(cluster / 8)]
            let isUsed = (byte >> UInt8(cluster % 8)) & 1 == 1
            if isUsed {
                if runStart == nil { runStart = cluster }
            } else if let start = runStart {
                if let range = ClusterRange(first: start, last: cluster - 1) {
                    runs.append(range)
                }
                runStart = nil
            }
        }
        if let start = runStart,
           let range = ClusterRange(first: start, last: totalClusters - 1) {
            runs.append(range)
        }
        return .success(runs)
    }
}

public enum NTFSAllocationFailure: Error, Equatable, Sendable {
    case mftRecord(NTFSMFTRecordFailure)
    case bitmapRecord(NTFSMFTRecordFailure)
    case bitmapDataNotRead
    case bitmap(NTFSBitmapFailure)
    case mftOutsidePartition(mftOffset: Int64, partitionLength: Int64)
    case partitionOverflow
}

/// The allocation domain the imager uses. `used` and `free` are **device**
/// byte extents: the partition offset has been added back and every extent is
/// clipped to the partition and merged. `usedClusters` stays volume-relative so
/// it can be compared with the ntfs-3g tools' cluster numbers.
public struct NTFSAllocationDomain: Equatable, Sendable {
    public let used: [ByteRange]
    public let free: [ByteRange]
    public let usedClusters: [ClusterRange]
    public let metadataRecords: ByteRange?

    public init(
        used: [ByteRange],
        free: [ByteRange],
        usedClusters: [ClusterRange],
        metadataRecords: ByteRange?
    ) {
        self.used = used
        self.free = free
        self.usedClusters = usedClusters
        self.metadataRecords = metadataRecords
    }
}

public enum NTFSAllocationOutcome: Equatable, Sendable {
    case known(NTFSAllocationDomain)
    /// Stage 0 could not determine the allocation. The caller falls back to
    /// whole-device passes; it must never treat this as "free space is
    /// unneeded".
    case unknown(NTFSAllocationFailure)

    public var domain: NTFSAllocationDomain? {
        if case .known(let domain) = self { return domain }
        return nil
    }

    public var failure: NTFSAllocationFailure? {
        if case .unknown(let failure) = self { return failure }
        return nil
    }
}

/// The pure stage-0 allocation step: parse `$MFT` record 0 and `$Bitmap` record
/// 6, decode the bitmap, then build the device extents.
public enum NTFSAllocation {
    public static func evaluate(
        geometry: NTFSBootGeometry,
        mftRecord: Data,
        bitmapRecord: Data,
        bitmapData: Data?,
        partitionOffset: Int64,
        partitionLength: Int64
    ) -> NTFSAllocationOutcome {
        let mft: NTFSDataAttribute
        switch NTFSMFTRecord.dataAttribute(
            in: mftRecord,
            bytesPerSector: geometry.bytesPerSector,
            volumeClusters: geometry.totalClusters
        ) {
        case .success(let value): mft = value
        case .failure(let failure): return .unknown(.mftRecord(failure))
        }

        let bitmap: NTFSDataAttribute
        switch NTFSMFTRecord.dataAttribute(
            in: bitmapRecord,
            bytesPerSector: geometry.bytesPerSector,
            volumeClusters: geometry.totalClusters
        ) {
        case .success(let value): bitmap = value
        case .failure(let failure): return .unknown(.bitmapRecord(failure))
        }

        let bytes: Data
        if let resident = bitmap.residentData {
            bytes = resident
        } else if let bitmapData {
            bytes = bitmapData
        } else {
            return .unknown(.bitmapDataNotRead)
        }

        let used: [ClusterRange]
        switch NTFSBitmap.usedClusters(bytes, totalClusters: geometry.totalClusters) {
        case .success(let value): used = value
        case .failure(let failure): return .unknown(.bitmap(failure))
        }

        switch allocationDomain(
            geometry: geometry,
            mftRuns: mft.runs,
            usedClusters: used,
            partitionOffset: partitionOffset,
            partitionLength: partitionLength
        ) {
        case .success(let domain): return .known(domain)
        case .failure(let failure): return .unknown(failure)
        }
    }

    /// Union of all `$MFT` data runs, the first-16-records metadata region and
    /// the bitmap's used clusters, in device bytes, merged, sorted and clipped
    /// to the partition. The complement inside the partition is the free space
    /// stage 2 reads last.
    public static func allocationDomain(
        geometry: NTFSBootGeometry,
        mftRuns: [NTFSDataRun],
        usedClusters: [ClusterRange],
        partitionOffset: Int64,
        partitionLength: Int64
    ) -> Result<NTFSAllocationDomain, NTFSAllocationFailure> {
        guard partitionOffset >= 0, partitionLength >= 0 else {
            return .failure(.mftOutsidePartition(
                mftOffset: geometry.mftOffset, partitionLength: partitionLength
            ))
        }
        let partitionEnd = partitionOffset + partitionLength
        guard partitionEnd >= partitionOffset else { return .failure(.partitionOverflow) }

        let volumeBytes = geometry.volumeBytes
        guard geometry.mftOffset >= 0,
              geometry.mftOffset < partitionLength,
              geometry.mftOffset < volumeBytes
        else {
            return .failure(.mftOutsidePartition(
                mftOffset: geometry.mftOffset, partitionLength: partitionLength
            ))
        }

        let clusterSize = Int64(geometry.clusterSize)
        guard clusterSize > 0 else {
            return .failure(.mftOutsidePartition(
                mftOffset: geometry.mftOffset, partitionLength: partitionLength
            ))
        }

        var relative: [ByteRange] = []

        // Every physical $MFT data run.
        for run in mftRuns {
            guard let lcn = run.lcn else { continue }
            relative.append(ByteRange(
                position: lcn * clusterSize,
                size: run.clusterCount * clusterSize
            ))
        }

        // The first 16 records, which stage 0 reads even if they sit inside a
        // larger $MFT run (the union absorbs the overlap).
        let metadataLength = min(
            geometry.metadataRecordsBytes,
            max(0, min(volumeBytes, partitionLength) - geometry.mftOffset)
        )
        let metadata: ByteRange? = metadataLength > 0
            ? ByteRange(position: geometry.mftOffset, size: metadataLength)
            : nil
        if let metadata { relative.append(metadata) }

        // The bitmap's used clusters.
        for range in usedClusters {
            relative.append(ByteRange(
                position: range.first * clusterSize,
                size: range.count * clusterSize
            ))
        }

        let device = relative.compactMap { extent -> ByteRange? in
            let start = max(extent.position + partitionOffset, partitionOffset)
            let end = min(extent.end + partitionOffset, partitionEnd)
            guard end > start else { return nil }
            return ByteRange(position: start, size: end - start)
        }
        let used = merge(device)
        let free = complement(of: used, partitionOffset: partitionOffset, partitionEnd: partitionEnd)

        return .success(NTFSAllocationDomain(
            used: used,
            free: free,
            usedClusters: usedClusters,
            metadataRecords: metadata.map {
                ByteRange(position: $0.position + partitionOffset, size: $0.size)
            }
        ))
    }

    /// Sorts and coalesces touching or overlapping extents. Adjacent extents
    /// (one ends exactly where the next starts) are one run: the imager reads
    /// bytes, not run boundaries.
    static func merge(_ extents: [ByteRange]) -> [ByteRange] {
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

    static func complement(
        of used: [ByteRange],
        partitionOffset: Int64,
        partitionEnd: Int64
    ) -> [ByteRange] {
        var free: [ByteRange] = []
        var cursor = partitionOffset
        for extent in used {
            if extent.position > cursor {
                free.append(ByteRange(position: cursor, size: extent.position - cursor))
            }
            cursor = max(cursor, extent.end)
        }
        if partitionEnd > cursor {
            free.append(ByteRange(position: cursor, size: partitionEnd - cursor))
        }
        return free
    }
}

/// A ddrescue "domain mapfile": `+` marks the blocks to read, `?` the blocks to
/// leave. `ddrescue -m <this file>` then restricts the run to the domain.
public enum DdrescueDomainMapfile {
    public static func render(domain: [ByteRange], deviceSize: Int64) -> String {
        var text = "# Mapfile. Created by disktriage\n"
        text += "# current_pos  current_status  current_pass\n"
        text += "0x00000000  ?  1\n"
        text += "#      pos        size  status\n"
        guard deviceSize > 0 else { return text }

        let clipped = domain.compactMap { extent -> ByteRange? in
            let start = max(0, extent.position)
            let end = min(extent.end, deviceSize)
            guard end > start else { return nil }
            return ByteRange(position: start, size: end - start)
        }
        let merged = NTFSAllocation.merge(clipped)

        var cursor: Int64 = 0
        for extent in merged {
            if extent.position > cursor {
                text += row(position: cursor, size: extent.position - cursor, status: "?")
            }
            text += row(position: extent.position, size: extent.size, status: "+")
            cursor = extent.end
        }
        if deviceSize > cursor {
            text += row(position: cursor, size: deviceSize - cursor, status: "?")
        }
        return text
    }

    private static func row(position: Int64, size: Int64, status: String) -> String {
        String(format: "0x%08llX  0x%08llX  %@\n", position, size, status)
    }
}
