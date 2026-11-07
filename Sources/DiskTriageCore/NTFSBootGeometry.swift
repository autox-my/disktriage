import Foundation

/// The NTFS geometry a `$MFT`/`$Bitmap` read needs, parsed from a primary or
/// backup boot sector. Pure: the caller reads the 512 bytes.
///
/// The record sizes use NTFS's signed encoding: a positive value is a count of
/// clusters; a negative value `-n` is `2^n` bytes.
public struct NTFSBootGeometry: Equatable, Sendable {
    public let bytesPerSector: Int
    public let sectorsPerCluster: Int
    public let totalSectors: Int64
    /// LCN of the `$MFT` data attribute.
    public let mftLCN: Int64
    /// LCN of `$MFTMirr`.
    public let mftMirrorLCN: Int64
    public let mftRecordSize: Int
    public let indexRecordSize: Int

    public init(
        bytesPerSector: Int,
        sectorsPerCluster: Int,
        totalSectors: Int64,
        mftLCN: Int64,
        mftMirrorLCN: Int64,
        mftRecordSize: Int,
        indexRecordSize: Int
    ) {
        self.bytesPerSector = bytesPerSector
        self.sectorsPerCluster = sectorsPerCluster
        self.totalSectors = totalSectors
        self.mftLCN = mftLCN
        self.mftMirrorLCN = mftMirrorLCN
        self.mftRecordSize = mftRecordSize
        self.indexRecordSize = indexRecordSize
    }

    public var clusterSize: Int { bytesPerSector * sectorsPerCluster }

    /// The BPB's total sectors are the volume's own extent. This can be one
    /// sector short of the partition (`mkntfs`), which is why the backup boot
    /// sector comes from the partition table instead.
    public var volumeBytes: Int64 { totalSectors * Int64(bytesPerSector) }

    public var totalClusters: Int64 {
        guard sectorsPerCluster > 0 else { return 0 }
        return totalSectors / Int64(sectorsPerCluster)
    }

    /// Volume-relative byte offset of the first `$MFT` record.
    public var mftOffset: Int64 { mftLCN * Int64(clusterSize) }

    /// `$MFT` records 0...15: `$MFT`, `$MFTMirr`, `$LogFile`, `$Volume`,
    /// `$AttrDef`, root, `$Bitmap`, ... Stage 0 reads exactly this region.
    public var metadataRecordsBytes: Int64 { 16 * Int64(mftRecordSize) }

    /// Parses a boot sector, applying the plan's rules first (OEM `NTFS    `,
    /// bytes/sector in {512,1024,2048,4096}, power-of-two sectors/cluster,
    /// `55 AA`) and then the allocation fields.
    public static func parse(_ sector: Data) -> Result<NTFSBootGeometry, NTFSBootGeometryFailure> {
        switch NTFSBootSectorRules.validateTyped(sector) {
        case .failure(let failure):
            return .failure(.invalidBootSector(failure))
        case .success(let boot):
            guard sector.count >= 0x48 else { return .failure(.invalidBootSector(.tooShort)) }
            let mftLCN = readLE64(sector, at: 0x30)
            let mftMirrorLCN = readLE64(sector, at: 0x38)
            let mftRaw = Int8(bitPattern: sector[0x40])
            let indexRaw = Int8(bitPattern: sector[0x44])

            let clusterSize = boot.clusterSize
            guard let mftRecordSize = Self.recordSize(raw: mftRaw, clusterSize: clusterSize) else {
                return .failure(.invalidMFTRecordSize(mftRaw))
            }
            guard let indexRecordSize = Self.recordSize(raw: indexRaw, clusterSize: clusterSize) else {
                return .failure(.invalidIndexRecordSize(indexRaw))
            }
            guard boot.totalSectors > 0, clusterSize > 0 else {
                return .failure(.invalidBootSector(.invalidSectorsPerCluster(boot.sectorsPerCluster)))
            }
            let totalClusters = boot.totalSectors / Int64(boot.sectorsPerCluster)
            guard mftLCN >= 0, mftLCN < totalClusters else {
                return .failure(.mftOutsideVolume(lcn: mftLCN, clusters: totalClusters))
            }
            return .success(NTFSBootGeometry(
                bytesPerSector: boot.bytesPerSector,
                sectorsPerCluster: boot.sectorsPerCluster,
                totalSectors: boot.totalSectors,
                mftLCN: mftLCN,
                mftMirrorLCN: mftMirrorLCN,
                mftRecordSize: mftRecordSize,
                indexRecordSize: indexRecordSize
            ))
        }
    }

    /// `-n` is `2^n` bytes, a positive value is that many clusters. Zero and a
    /// shift that cannot be represented are failures, never a guess.
    static func recordSize(raw: Int8, clusterSize: Int) -> Int? {
        guard raw != 0 else { return nil }
        if raw > 0 {
            let (bytes, overflow) = Int(raw).multipliedReportingOverflow(by: clusterSize)
            guard !overflow, bytes > 0 else { return nil }
            return bytes
        }
        let shift = Int(-Int(raw))
        guard shift >= 1, shift < 63 else { return nil }
        let bytes = 1 << shift
        return bytes > 0 ? bytes : nil
    }

    static func readLE64(_ data: Data, at offset: Int) -> Int64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (8 * UInt64(i))
        }
        return Int64(bitPattern: value)
    }
}

/// Which of the two boot sectors supplied the geometry. The report says which
/// one was used; the tool never silently prefers the backup.
public enum BootSectorSource: String, Equatable, Sendable {
    case primary
    case backup
}

public struct NTFSBootGeometrySelection: Equatable, Sendable {
    public let geometry: NTFSBootGeometry
    public let source: BootSectorSource
    /// Why the primary was not usable, `nil` when it was.
    public let primaryFailure: NTFSBootGeometryFailure?

    public init(
        geometry: NTFSBootGeometry,
        source: BootSectorSource,
        primaryFailure: NTFSBootGeometryFailure?
    ) {
        self.geometry = geometry
        self.source = source
        self.primaryFailure = primaryFailure
    }
}

public enum NTFSBootGeometryFailure: Error, Equatable, Sendable {
    case invalidBootSector(NTFSBootSectorFailure)
    case invalidMFTRecordSize(Int8)
    case invalidIndexRecordSize(Int8)
    case mftOutsideVolume(lcn: Int64, clusters: Int64)
}

public enum NTFSBootGeometrySelectionFailure: Error, Equatable, Sendable {
    case noUsableBootSector(
        primary: NTFSBootGeometryFailure,
        backup: NTFSBootGeometryFailure?
    )
}

extension NTFSBootGeometry {
    /// Step A can only read the primary. If it is not usable the backup is
    /// validated with the same rules and, when good, its geometry is used and
    /// the report names the backup. Two bad sectors are a typed failure, never
    /// an empty geometry.
    public static func select(
        primary: Data,
        backup: Data?
    ) -> Result<NTFSBootGeometrySelection, NTFSBootGeometrySelectionFailure> {
        switch parse(primary) {
        case .success(let geometry):
            return .success(NTFSBootGeometrySelection(
                geometry: geometry,
                source: .primary,
                primaryFailure: nil
            ))
        case .failure(let primaryFailure):
            guard let backup else {
                return .failure(.noUsableBootSector(primary: primaryFailure, backup: nil))
            }
            switch parse(backup) {
            case .success(let geometry):
                return .success(NTFSBootGeometrySelection(
                    geometry: geometry,
                    source: .backup,
                    primaryFailure: primaryFailure
                ))
            case .failure(let backupFailure):
                return .failure(.noUsableBootSector(
                    primary: primaryFailure,
                    backup: backupFailure
                ))
            }
        }
    }
}
