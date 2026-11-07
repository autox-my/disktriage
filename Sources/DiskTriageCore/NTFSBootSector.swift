import Foundation

/// The fields of an NTFS boot sector that decide whether the sector may be
/// written over a damaged primary, and whether a volume is NTFS at all.
public struct NTFSBootSector: Equatable, Sendable {
    public let oemID: String
    public let bytesPerSector: Int
    public let sectorsPerCluster: Int
    public let totalSectors: Int64
    /// `bytesPerSector × sectorsPerCluster`, the unit of every volume-relative
    /// cluster number the ntfs-3g tools print.
    public let clusterSize: Int

    public init(
        oemID: String,
        bytesPerSector: Int,
        sectorsPerCluster: Int,
        totalSectors: Int64,
        clusterSize: Int
    ) {
        self.oemID = oemID
        self.bytesPerSector = bytesPerSector
        self.sectorsPerCluster = sectorsPerCluster
        self.totalSectors = totalSectors
        self.clusterSize = clusterSize
    }
}

public enum NTFSBootSectorValidation: Equatable, Sendable {
    case valid(NTFSBootSector)
    /// Why the 512 bytes are not a usable NTFS boot sector. The reason is
    /// report text, not a status.
    case invalid(String)

    public var bootSector: NTFSBootSector? {
        if case .valid(let boot) = self { return boot }
        return nil
    }

    public var reason: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

/// The boot-sector rules from diskdoctor.md §8. The backup-sector offset is the
/// formula P0 row 11 measured, not one derived from the BPB: `mkntfs` leaves
/// `total_sectors` one sector short, and the disk's last sector is the wrong
/// sector on a whole-disk image.
public enum NTFSBootSectorRules {
    public static let oemID = "NTFS    "
    public static let allowedSectorSizes: Set<Int> = [512, 1024, 2048, 4096]
    public static let bootSignature: [UInt8] = [0x55, 0xAA]

    public static func validate(_ sector: Data) -> NTFSBootSectorValidation {
        guard sector.count >= 512 else {
            return .invalid("the boot sector is shorter than 512 bytes")
        }
        guard sector[3..<11] == Data(oemID.utf8) else {
            return .invalid("the OEM ID is not 'NTFS    '")
        }
        guard sector[510] == bootSignature[0], sector[511] == bootSignature[1] else {
            return .invalid("the 55 AA boot signature is missing")
        }
        let bytesPerSector = Int(sector[0x0B]) | (Int(sector[0x0C]) << 8)
        guard allowedSectorSizes.contains(bytesPerSector) else {
            return .invalid("bytes per sector \(bytesPerSector) is not 512, 1024, 2048 or 4096")
        }
        let sectorsPerCluster = Int(sector[0x0D])
        guard sectorsPerCluster >= 1,
              sectorsPerCluster <= 128,
              sectorsPerCluster & (sectorsPerCluster - 1) == 0
        else {
            return .invalid("sectors per cluster \(sectorsPerCluster) is not a power of two in 1...128")
        }
        let totalSectors = (0..<8).reduce(UInt64(0)) { value, i in
            value | (UInt64(sector[0x28 + i]) << (8 * UInt64(i)))
        }
        return .valid(NTFSBootSector(
            oemID: oemID,
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            totalSectors: Int64(bitPattern: totalSectors),
            clusterSize: bytesPerSector * sectorsPerCluster
        ))
    }

    /// The backup boot sector is the last 512 bytes of the **partition**:
    /// `partition_offset + partition_length_bytes - 512`. The length comes from
    /// the partition table, never from the BPB's `total_sectors`.
    public static func backupOffset(partitionOffset: Int64, partitionLengthBytes: Int64) -> Int64? {
        guard partitionOffset >= 0, partitionLengthBytes >= 512 else { return nil }
        return partitionOffset + partitionLengthBytes - 512
    }
}

/// The cheap volume magics `inspect` can name without a driver. "Native
/// read-only attach not implemented yet" is the honest answer for every one of
/// them in this version; naming the filesystem is still better than guessing.
public enum FileSystemKind: String, Equatable, Sendable {
    case ntfs
    case apfs
    case hfsPlus = "hfs+"
    case exfat
    case fat
    case unknown
}

public enum FileSystemDetector {
    /// `prefix` is the first bytes of the volume (at least 1026 for HFS+, 2048
    /// is what the CLI reads). A whole-disk image is detected through its
    /// partition table first; this runs on the partition's own first bytes.
    public static func detect(_ prefix: Data) -> FileSystemKind {
        if prefix.count >= 11, prefix[3..<11] == Data("NTFS    ".utf8) {
            return .ntfs
        }
        if prefix.count >= 36, prefix[32..<36] == Data("NXSB".utf8) {
            return .apfs
        }
        if prefix.count >= 11, prefix[3..<11] == Data("EXFAT   ".utf8) {
            return .exfat
        }
        if prefix.count >= 90, prefix[82..<90] == Data("FAT32   ".utf8) {
            return .fat
        }
        if prefix.count >= 62, prefix[54..<62] == Data("FAT16   ".utf8) {
            return .fat
        }
        if prefix.count >= 62, prefix[54..<62] == Data("FAT12   ".utf8) {
            return .fat
        }
        if prefix.count >= 1026, prefix[1024..<1026] == Data([0x48, 0x2B]) || prefix[1024..<1026] == Data([0x48, 0x58]) {
            return .hfsPlus
        }
        return .unknown
    }
}
