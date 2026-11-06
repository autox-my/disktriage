import Foundation

/// The fields of a DiskArbitration disk description that the mount guard
/// reads. It is a plain value: no DiskArbitration import, so the decision is
/// testable with recorded descriptions and no hardware.
public struct DiskDescription: Equatable, Sendable {
    /// `DADeviceInternal` — true for a built-in disk, false for an external
    /// one, nil when the key is absent or unreadable (unknown is not false).
    public let isInternal: Bool?
    /// `DADeviceProtocol` — "USB", "Thunderbolt", "Apple Fabric",
    /// "Virtual Interface", ...
    public let protocolName: String?
    /// `DAVolumeKind` — the filesystem personality, e.g. `iboysoft_NTFS`.
    public let volumeKind: String?
    /// `DAMediaWhole` — a whole disk rather than a partition.
    public let mediaWhole: Bool?
    /// `DADeviceModel` — e.g. "Disk Image".
    public let model: String?

    public init(
        isInternal: Bool? = nil,
        protocolName: String? = nil,
        volumeKind: String? = nil,
        mediaWhole: Bool? = nil,
        model: String? = nil
    ) {
        self.isInternal = isInternal
        self.protocolName = protocolName
        self.volumeKind = volumeKind
        self.mediaWhole = mediaWhole
        self.model = model
    }

    /// Reads the recorded DADiskDescription keys out of a description
    /// dictionary. The shim casts `DADiskCopyDescription` to this shape.
    public init(daDescription: [String: Any]) {
        self.init(
            isInternal: Self.bool(daDescription["DADeviceInternal"]),
            protocolName: daDescription["DADeviceProtocol"] as? String,
            volumeKind: daDescription["DAVolumeKind"] as? String,
            mediaWhole: Self.bool(daDescription["DAMediaWhole"]),
            model: daDescription["DADeviceModel"] as? String
        )
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }
}

/// What the guard does with one mount approval.
public enum GuardVerdict: String, Equatable, Sendable {
    case approve
    case dissent
}

/// The protocols of a physical disk that is not built in. `DADeviceInternal`
/// must also be false: this list only says which protocol values mean a real
/// drive, so "Virtual Interface" (a disk image) is deliberately absent.
public let externalPhysicalProtocols: Set<String> = [
    "USB",
    "Thunderbolt",
    "FireWire",
    "SAS",
    "SATA",
    "Fibre Channel",
]

/// The pure mount-guard decision (diskdoctor.md section 8, P0 row 5).
///
/// Dissent only for an external physical disk: `DADeviceInternal == false` and
/// a physical protocol. An absent field is unknown and approves, because the
/// guard must never veto a mount it cannot positively identify.
public func guardDecision(_ description: DiskDescription) -> GuardVerdict {
    // Both keys must positively say "external physical disk". An absent or
    // unreadable key is unknown, and unknown approves.
    guard description.isInternal == false,
          let protocolName = description.protocolName,
          externalPhysicalProtocols.contains(protocolName) else {
        return .approve
    }
    return .dissent
}
