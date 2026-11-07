import Foundation

/// One run of a non-resident attribute. `lcn` is `nil` for a sparse run (a run
/// whose mapping-pair header has no offset field).
public struct NTFSDataRun: Equatable, Sendable {
    public let vcn: Int64
    public let clusterCount: Int64
    public let lcn: Int64?

    public init(vcn: Int64, clusterCount: Int64, lcn: Int64?) {
        self.vcn = vcn
        self.clusterCount = clusterCount
        self.lcn = lcn
    }

    public var isSparse: Bool { lcn == nil }
    public var lastVCN: Int64 { vcn + clusterCount - 1 }
}

/// A `$DATA` attribute after the update sequence array has been applied.
/// Resident data is bytes; non-resident data is a run list, never both.
public struct NTFSDataAttribute: Equatable, Sendable {
    public let residentData: Data?
    public let runs: [NTFSDataRun]
    public let dataSize: Int64

    public init(residentData: Data?, runs: [NTFSDataRun], dataSize: Int64) {
        self.residentData = residentData
        self.runs = runs
        self.dataSize = dataSize
    }

    public var isResident: Bool { residentData != nil }
}

public enum NTFSRunListFailure: Error, Equatable, Sendable {
    case empty
    case tooManyRuns(Int)
    case truncatedField(offset: Int)
    case missingTerminator
    case zeroLengthRun
    case invalidRunHeader(UInt8)
    case negativeLCN(Int64)
    case overlappingLCNs
    case runPastVolumeEnd(lcn: Int64, count: Int64, volumeClusters: Int64)
}

public enum NTFSRunList {
    /// The NTFS mapping-pairs decoder. The offset field is a **signed** delta
    /// from the previous LCN; a zero-length offset field is a sparse run.
    /// Runs are rejected when they overlap, leave the volume or exceed the
    /// fragmentation cap, instead of being guessed at.
    public static func decode(
        _ data: Data,
        volumeClusters: Int64? = nil,
        maxRuns: Int = 65_536
    ) -> Result<[NTFSDataRun], NTFSRunListFailure> {
        guard !data.isEmpty else { return .failure(.empty) }
        var runs: [NTFSDataRun] = []
        var offset = 0
        var currentLCN: Int64 = 0
        var currentVCN: Int64 = 0
        var terminated = false

        while offset < data.count {
            let header = data[offset]
            offset += 1
            if header == 0 {
                terminated = true
                break
            }
            let lengthSize = Int(header & 0x0F)
            let offsetSize = Int(header >> 4)
            guard lengthSize > 0, lengthSize <= 8, offsetSize <= 8 else {
                return .failure(.invalidRunHeader(header))
            }
            guard offset + lengthSize <= data.count else {
                return .failure(.truncatedField(offset: offset))
            }
            var rawLength: UInt64 = 0
            for i in 0..<lengthSize {
                rawLength |= UInt64(data[offset + i]) << (8 * UInt64(i))
            }
            offset += lengthSize
            guard rawLength > 0, rawLength <= UInt64(Int64.max) else {
                return .failure(.zeroLengthRun)
            }
            let count = Int64(rawLength)

            var lcn: Int64?
            if offsetSize > 0 {
                guard offset + offsetSize <= data.count else {
                    return .failure(.truncatedField(offset: offset))
                }
                var raw: UInt64 = 0
                for i in 0..<offsetSize {
                    raw |= UInt64(data[offset + i]) << (8 * UInt64(i))
                }
                offset += offsetSize
                let delta: Int64
                if offsetSize == 8 {
                    delta = Int64(bitPattern: raw)
                } else {
                    let signBit = UInt64(1) << (8 * UInt64(offsetSize) - 1)
                    if raw & signBit != 0 {
                        let mask = ~UInt64(0) << (8 * UInt64(offsetSize))
                        delta = Int64(bitPattern: raw | mask)
                    } else {
                        delta = Int64(bitPattern: raw)
                    }
                }
                let (next, overflow) = currentLCN.addingReportingOverflow(delta)
                guard !overflow else { return .failure(.negativeLCN(delta)) }
                guard next >= 0 else { return .failure(.negativeLCN(next)) }
                currentLCN = next
                lcn = next
            }

            if runs.count >= maxRuns { return .failure(.tooManyRuns(maxRuns)) }
            if let volumeClusters, let lcn {
                let (end, overflow) = lcn.addingReportingOverflow(count)
                guard !overflow, end <= volumeClusters else {
                    return .failure(.runPastVolumeEnd(
                        lcn: lcn, count: count, volumeClusters: volumeClusters
                    ))
                }
            }
            runs.append(NTFSDataRun(vcn: currentVCN, clusterCount: count, lcn: lcn))
            currentVCN += count
        }

        guard terminated else { return .failure(.missingTerminator) }
        guard !runs.isEmpty else { return .failure(.empty) }

        let intervals = runs.compactMap { run -> (Int64, Int64)? in
            guard let lcn = run.lcn else { return nil }
            return (lcn, lcn + run.clusterCount)
        }.sorted { $0.0 < $1.0 }
        for index in 1..<max(intervals.count, 1) where intervals.count > 1 {
            if intervals[index].0 < intervals[index - 1].1 {
                return .failure(.overlappingLCNs)
            }
        }
        return .success(runs)
    }
}

public enum NTFSMFTRecordFailure: Error, Equatable, Sendable {
    case tooShort(Int)
    case badMagic
    case recordNotSectorAligned(recordBytes: Int, bytesPerSector: Int)
    case badUpdateSequenceArray(offset: Int, count: Int)
    case fixupMismatch(sector: Int, expected: UInt16, found: UInt16)
    case truncatedAttribute(offset: Int)
    case attributeListUnsupported
    case dataAttributeMissing
    case multipleDataAttributes
    case invalidDataSize
    case invalidRunList(NTFSRunListFailure)
}

/// An MFT record. The update sequence array is applied before anything else is
/// read: a record whose sector-tail words do not match the USN is torn (or all
/// zeroes) and is a typed failure, never a record with guessed attributes.
public enum NTFSMFTRecord {
    static let fileMagic: UInt32 = 0x454C_4946 // "FILE" little-endian

    public static func applyFixups(
        _ record: Data,
        bytesPerSector: Int
    ) -> Result<Data, NTFSMFTRecordFailure> {
        guard record.count >= 48 else { return .failure(.tooShort(record.count)) }
        guard bytesPerSector > 0 else {
            return .failure(.recordNotSectorAligned(
                recordBytes: record.count, bytesPerSector: bytesPerSector
            ))
        }
        guard readLE32(record, at: 0) == fileMagic else { return .failure(.badMagic) }
        guard record.count % bytesPerSector == 0 else {
            return .failure(.recordNotSectorAligned(
                recordBytes: record.count, bytesPerSector: bytesPerSector
            ))
        }
        let sectors = record.count / bytesPerSector
        let usaOffset = Int(readLE16(record, at: 0x04))
        let usaCount = Int(readLE16(record, at: 0x06))
        guard usaCount == sectors + 1,
              usaOffset >= 0,
              usaOffset + usaCount * 2 <= record.count
        else {
            return .failure(.badUpdateSequenceArray(offset: usaOffset, count: usaCount))
        }

        var fixed = record
        let usn = readLE16(record, at: usaOffset)
        for sector in 0..<sectors {
            let tail = (sector + 1) * bytesPerSector - 2
            let found = readLE16(record, at: tail)
            guard found == usn else {
                return .failure(.fixupMismatch(sector: sector, expected: usn, found: found))
            }
            let replacement = readLE16(record, at: usaOffset + 2 * (sector + 1))
            fixed[tail] = UInt8(replacement & 0xFF)
            fixed[tail + 1] = UInt8(replacement >> 8)
        }
        return .success(fixed)
    }

    /// Decodes the unnamed `$DATA` (0x80) attribute. An `$ATTRIBUTE_LIST`
    /// (0x20) anywhere in the record is reported as unsupported: following
    /// extension records is deliberately not guessed at here.
    public static func dataAttribute(
        in record: Data,
        bytesPerSector: Int,
        volumeClusters: Int64? = nil
    ) -> Result<NTFSDataAttribute, NTFSMFTRecordFailure> {
        let fixed: Data
        switch applyFixups(record, bytesPerSector: bytesPerSector) {
        case .success(let value): fixed = value
        case .failure(let failure): return .failure(failure)
        }

        let attributeStart = Int(readLE16(fixed, at: 0x14))
        let bytesInUse = Int(readLE32(fixed, at: 0x18))
        guard attributeStart >= 0, attributeStart < fixed.count else {
            return .failure(.truncatedAttribute(offset: attributeStart))
        }
        let limit = min(bytesInUse, fixed.count)
        guard limit > attributeStart else {
            return .failure(.truncatedAttribute(offset: attributeStart))
        }

        var offset = attributeStart
        var found: NTFSDataAttribute?
        while offset + 4 <= limit {
            let type = readLE32(fixed, at: offset)
            if type == 0xFFFF_FFFF { break }
            guard offset + 16 <= limit else {
                return .failure(.truncatedAttribute(offset: offset))
            }
            let length = Int(readLE32(fixed, at: offset + 4))
            guard length >= 16, offset + length <= limit else {
                return .failure(.truncatedAttribute(offset: offset))
            }
            let end = offset + length

            if type == 0x20 { return .failure(.attributeListUnsupported) }

            if type == 0x80, fixed[offset + 9] == 0 {
                guard found == nil else { return .failure(.multipleDataAttributes) }
                switch decodeDataAttribute(
                    fixed, at: offset, length: length,
                    volumeClusters: volumeClusters
                ) {
                case .success(let attribute): found = attribute
                case .failure(let failure): return .failure(failure)
                }
            }
            offset = end
        }

        guard let found else { return .failure(.dataAttributeMissing) }
        return .success(found)
    }

    private static func decodeDataAttribute(
        _ record: Data,
        at offset: Int,
        length: Int,
        volumeClusters: Int64?
    ) -> Result<NTFSDataAttribute, NTFSMFTRecordFailure> {
        let nonResident = record[offset + 8] != 0
        if !nonResident {
            let valueLength = Int(readLE32(record, at: offset + 0x10))
            let valueOffset = Int(readLE16(record, at: offset + 0x14))
            guard valueOffset >= 0, valueLength >= 0,
                  valueOffset + valueLength <= length
            else {
                return .failure(.truncatedAttribute(offset: offset))
            }
            let start = offset + valueOffset
            let value = record[start..<(start + valueLength)]
            return .success(NTFSDataAttribute(
                residentData: Data(value),
                runs: [],
                dataSize: Int64(valueLength)
            ))
        }

        let runListOffset = Int(readLE16(record, at: offset + 0x20))
        let dataSizeRaw = readLE64(record, at: offset + 0x30)
        let runStart = offset + runListOffset
        guard runListOffset >= 0x40, runStart < offset + length else {
            return .failure(.truncatedAttribute(offset: offset))
        }
        let runData = Data(record[runStart..<(offset + length)])
        let runs: [NTFSDataRun]
        switch NTFSRunList.decode(runData, volumeClusters: volumeClusters) {
        case .success(let value): runs = value
        case .failure(let failure): return .failure(.invalidRunList(failure))
        }
        guard dataSizeRaw >= 0 else { return .failure(.invalidDataSize) }
        return .success(NTFSDataAttribute(
            residentData: nil,
            runs: runs,
            dataSize: dataSizeRaw
        ))
    }

    private static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        return value
    }

    private static func readLE64(_ data: Data, at offset: Int) -> Int64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
        return Int64(bitPattern: value)
    }
}
