import Foundation

/// What a stage-0 extent is for. The order of the plan is the read order.
public enum Stage0ReadPurpose: String, Equatable, Sendable {
    case partitionTable
    case gptHeader
    case gptEntries
    case gptBackupHeader
    case gptBackupEntries
    case primaryBootSector
    case backupBootSector
    case mftRecords
}

public struct Stage0ReadExtent: Equatable, Sendable {
    public let position: Int64
    public let size: Int64
    public let purpose: Stage0ReadPurpose

    public init(position: Int64, size: Int64, purpose: Stage0ReadPurpose) {
        self.position = position
        self.size = size
        self.purpose = purpose
    }

    public var range: ByteRange { ByteRange(position: position, size: size) }
}

/// The ordered byte extents stage 0 must read. Pure: the caller performs the
/// reads.
///
/// Step A (no geometry): the partition table (including the GPT backup header
/// and entry array), the primary boot sector and the **backup** boot sector at
/// `partitionOffset + partitionLength - 512` — the partition table's length,
/// never the BPB's `total_sectors`.
///
/// Step B (geometry from the primary *or* the backup): the same extents, then
/// the first 16 MFT records (`$MFT` through `$Bitmap` and beyond) at the MFT
/// LCN the geometry names.
public enum NTFSStage0ReadPlan {
    public static func plan(
        partitionOffset: Int64,
        partitionLength: Int64,
        geometry: NTFSBootGeometry? = nil,
        partitionTable: PartitionTable? = nil,
        gptHeader: GPTHeaderLocation? = nil,
        deviceSize: Int64? = nil
    ) -> [Stage0ReadExtent] {
        var extents: [Stage0ReadExtent] = []

        // Partition table sectors.
        if let partitionTable {
            switch partitionTable.scheme {
            case .mbr:
                extents.append(Stage0ReadExtent(
                    position: 0, size: 512, purpose: .partitionTable
                ))
            case .gpt:
                extents.append(Stage0ReadExtent(
                    position: 0, size: 512, purpose: .partitionTable
                ))
                extents.append(Stage0ReadExtent(
                    position: 512, size: 512, purpose: .gptHeader
                ))
                if let gptHeader {
                    extents.append(Stage0ReadExtent(
                        position: gptHeader.entryOffset,
                        size: Int64(gptHeader.entryBytes),
                        purpose: .gptEntries
                    ))
                }
                if let deviceSize, deviceSize >= 512 {
                    let backupHeader = deviceSize - 512
                    extents.append(Stage0ReadExtent(
                        position: backupHeader, size: 512, purpose: .gptBackupHeader
                    ))
                    if let gptHeader {
                        let entryBytes = Int64(gptHeader.entryBytes)
                        let backupEntries = backupHeader - entryBytes
                        if backupEntries >= 0 {
                            extents.append(Stage0ReadExtent(
                                position: backupEntries,
                                size: entryBytes,
                                purpose: .gptBackupEntries
                            ))
                        }
                    }
                }
            }
        }

        guard partitionOffset >= 0, partitionLength >= 512 else { return extents }

        extents.append(Stage0ReadExtent(
            position: partitionOffset,
            size: 512,
            purpose: .primaryBootSector
        ))
        if let backupOffset = NTFSBootSectorRules.backupOffset(
            partitionOffset: partitionOffset,
            partitionLengthBytes: partitionLength
        ) {
            extents.append(Stage0ReadExtent(
                position: backupOffset,
                size: 512,
                purpose: .backupBootSector
            ))
        }

        if let geometry {
            let mftStart = partitionOffset + geometry.mftOffset
            let available = min(partitionLength, geometry.volumeBytes) - geometry.mftOffset
            let length = min(geometry.metadataRecordsBytes, max(0, available))
            if length > 0 {
                extents.append(Stage0ReadExtent(
                    position: mftStart,
                    size: length,
                    purpose: .mftRecords
                ))
            }
        }

        return extents
    }
}
