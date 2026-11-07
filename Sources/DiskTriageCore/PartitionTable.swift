import Foundation

/// The partition-table shapes `inspect` needs. Pure: the caller reads the
/// sectors from the image and hands them in, so every rule is table-driven and
/// no test touches a disk.
public enum PartitionScheme: String, Equatable, Sendable {
    case mbr
    case gpt
}

/// One partition entry. `startLBA` and `sectorCount` are the table's own units
/// (512-byte LBAs on every image this tool reads); the byte values are what an
/// extractor uses.
public struct DiskPartition: Equatable, Sendable {
    /// 1-based slot, as the table names it.
    public let index: Int
    /// MBR type byte, `nil` for a GPT entry.
    public let mbrType: UInt8?
    /// The raw 16-byte GPT type GUID in on-disk byte order, `nil` for MBR.
    public let typeGUID: [UInt8]?
    public let startLBA: Int64
    public let sectorCount: Int64
    public let sectorSize: Int

    public init(
        index: Int,
        mbrType: UInt8?,
        typeGUID: [UInt8]?,
        startLBA: Int64,
        sectorCount: Int64,
        sectorSize: Int
    ) {
        self.index = index
        self.mbrType = mbrType
        self.typeGUID = typeGUID
        self.startLBA = startLBA
        self.sectorCount = sectorCount
        self.sectorSize = sectorSize
    }

    public var byteOffset: Int64 { startLBA * Int64(sectorSize) }
    public var byteLength: Int64 { sectorCount * Int64(sectorSize) }
}

public struct PartitionTable: Equatable, Sendable {
    public let scheme: PartitionScheme
    public let sectorSize: Int
    public let partitions: [DiskPartition]

    public init(scheme: PartitionScheme, sectorSize: Int, partitions: [DiskPartition]) {
        self.scheme = scheme
        self.sectorSize = sectorSize
        self.partitions = partitions
    }

    /// A protective MBR (type 0xEE) is the GPT marker, never a data partition.
    public var isProtective: Bool {
        scheme == .mbr && partitions.contains { $0.mbrType == PartitionTableParser.protectiveMBRType }
    }

    /// MBR type 0x07 and the GPT Microsoft basic-data GUID are the NTFS
    /// candidates. Whether the boot sector really is NTFS is checked later,
    /// against the volume's own OEM ID.
    public var ntfsCandidates: [DiskPartition] {
        switch scheme {
        case .mbr:
            return partitions.filter { $0.mbrType == PartitionTableParser.ntfsMBRType }
        case .gpt:
            return partitions.filter { $0.typeGUID == PartitionTableParser.microsoftBasicDataGUID }
        }
    }
}

/// A parsed GPT header: where the entry array lives and how large it is.
public struct GPTHeaderLocation: Equatable, Sendable {
    public let entriesLBA: Int64
    public let entryCount: Int
    public let entrySize: Int
    public let sectorSize: Int

    public init(entriesLBA: Int64, entryCount: Int, entrySize: Int, sectorSize: Int) {
        self.entriesLBA = entriesLBA
        self.entryCount = entryCount
        self.entrySize = entrySize
        self.sectorSize = sectorSize
    }

    /// The bytes to read from the entry array. 128 × 128 is the usual 16 KiB;
    /// the bound keeps a corrupt header from asking for a huge read.
    public var entryBytes: Int { entryCount * entrySize }
    public var entryOffset: Int64 { entriesLBA * Int64(sectorSize) }
}

public enum PartitionTableParser {
    public static let protectiveMBRType: UInt8 = 0xEE
    public static let ntfsMBRType: UInt8 = 0x07

    /// `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`, in on-disk byte order.
    public static let microsoftBasicDataGUID: [UInt8] = [
        0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
        0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7,
    ]

    /// Parses the first 512 bytes. Returns `nil` only when the sector is too
    /// short or lacks `55 AA`; a table with no usable entries is an empty table,
    /// which lets the caller treat the image as a bare volume.
    public static func parseMBR(_ sector: Data, sectorSize: Int = 512) -> PartitionTable? {
        guard sector.count >= 512, sector[510] == 0x55, sector[511] == 0xAA else { return nil }
        var partitions: [DiskPartition] = []
        for index in 0..<4 {
            let base = 446 + index * 16
            let type = sector[base + 4]
            let start = readLE32(sector, at: base + 8)
            let count = readLE32(sector, at: base + 12)
            guard type != 0, start != 0, count != 0 else { continue }
            partitions.append(DiskPartition(
                index: index + 1,
                mbrType: type,
                typeGUID: nil,
                startLBA: Int64(start),
                sectorCount: Int64(count),
                sectorSize: sectorSize
            ))
        }
        return PartitionTable(scheme: .mbr, sectorSize: sectorSize, partitions: partitions)
    }

    /// Parses the GPT header sector (LBA 1). The CRC is not verified: the
    /// array's boundaries and the type GUIDs are what the extractor needs, and
    /// a bad CRC never makes a bad parse safe (the boot-sector OEM still is).
    public static func parseGPTHeader(_ sector: Data, sectorSize: Int = 512) -> GPTHeaderLocation? {
        guard sector.count >= 92, sector.starts(with: Data("EFI PART".utf8)) else { return nil }
        let headerSize = Int(readLE32(sector, at: 12))
        guard headerSize >= 92, headerSize <= 512 else { return nil }
        let entriesLBA = Int64(bitPattern: readLE64(sector, at: 72))
        let count = Int(readLE32(sector, at: 80))
        let size = Int(readLE32(sector, at: 84))
        guard count > 0, count <= 4096, size >= 128, size <= 1024, size % 8 == 0 else { return nil }
        return GPTHeaderLocation(entriesLBA: entriesLBA, entryCount: count, entrySize: size, sectorSize: sectorSize)
    }

    /// Parses the entry array. A short array is not a partial table: it cannot
    /// be trusted, so it is `nil` rather than a table with missing rows.
    public static func parseGPTEntries(
        _ location: GPTHeaderLocation,
        entries: Data
    ) -> PartitionTable? {
        guard entries.count >= location.entryBytes else { return nil }
        var partitions: [DiskPartition] = []
        for index in 0..<location.entryCount {
            let base = index * location.entrySize
            let type = Array(entries[(base + 0)..<(base + 16)])
            guard type.contains(where: { $0 != 0 }) else { continue }
            let first = Int64(bitPattern: readLE64(entries, at: base + 32))
            let last = Int64(bitPattern: readLE64(entries, at: base + 40))
            guard last >= first, first != 0 else { continue }
            partitions.append(DiskPartition(
                index: index + 1,
                mbrType: nil,
                typeGUID: type,
                startLBA: first,
                sectorCount: last - first + 1,
                sectorSize: location.sectorSize
            ))
        }
        return PartitionTable(scheme: .gpt, sectorSize: location.sectorSize, partitions: partitions)
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { value, i in
            value | (UInt32(data[offset + i]) << (8 * UInt32(i)))
        }
    }

    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return (0..<8).reduce(UInt64(0)) { value, i in
            value | (UInt64(data[offset + i]) << (8 * UInt64(i)))
        }
    }
}
