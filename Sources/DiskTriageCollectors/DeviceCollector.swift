import Foundation
import DiskTriageCore

/// The identity fields `diskutil info -plist` actually exposes for a whole
/// disk. `serial` is `nil` on this build's internal NVMe, which is a fact about
/// the recording, not an empty string.
public struct DeviceIdentity: Sendable, Equatable {
    public let bsd: String
    public let sizeBytes: Int64?
    public let model: String?
    public let serial: String?
    /// `hdd`, `ssd` or `unknown` (diskdoctor.md §5 step [2]).
    public let media: String
    /// `usb`, `sata`, `nvme`, … after the `BusProtocol` mapping below.
    public let bus: String?
    public let removable: Bool?
    public let blockSize: Int64?
    public let internalDisk: Bool?
    /// `Virtual`, `Physical` or `Unknown` from `diskutil info -plist`. The
    /// internal Apple NVMe reports `Unknown`; synthesized APFS containers and
    /// disk images report `Virtual`, which `list` filters out.
    public let virtualOrPhysical: String?

    public init(
        bsd: String,
        sizeBytes: Int64? = nil,
        model: String? = nil,
        serial: String? = nil,
        media: String = "unknown",
        bus: String? = nil,
        removable: Bool? = nil,
        blockSize: Int64? = nil,
        internalDisk: Bool? = nil,
        virtualOrPhysical: String? = nil
    ) {
        self.bsd = bsd
        self.sizeBytes = sizeBytes
        self.model = model
        self.serial = serial
        self.media = media
        self.bus = bus
        self.removable = removable
        self.blockSize = blockSize
        self.internalDisk = internalDisk
        self.virtualOrPhysical = virtualOrPhysical
    }
}

/// One device section plus the status it was collected with.
public struct DeviceCollection: Sendable, Equatable {
    public let status: SignalStatus
    public let identity: DeviceIdentity?
    public let reason: String?

    public init(status: SignalStatus, identity: DeviceIdentity? = nil, reason: String? = nil) {
        self.status = status
        self.identity = identity
        self.reason = reason
    }
}

/// The whole-disk enumeration and the status of the command that produced it.
public struct DiskEnumeration: Sendable, Equatable {
    public let status: SignalStatus
    public let disks: [String]
    public let reason: String?

    public init(status: SignalStatus, disks: [String] = [], reason: String? = nil) {
        self.status = status
        self.disks = disks
        self.reason = reason
    }
}

public enum DeviceParseError: Error, Equatable {
    case notAPlist
    case notADictionary
    case missingDeviceIdentifier
}

/// The one collector that can be verified without external hardware: identity
/// from `diskutil info -plist`, read-only and without root (diskdoctor.md §4).
public struct DeviceCollector: Sendable {
    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
    }

    /// `[0] enumerate` for the decision tree: whole disks only, never slices.
    public func enumerateWholeDisks() -> [String] {
        enumerate().disks
    }

    /// Enumeration that keeps its status: an empty list from a failed command
    /// is not "no disks attached" (diskdoctor.md §2.3).
    public func enumerate() -> DiskEnumeration {
        let result = executor.run(.diskutilList)
        guard result.outcome == .ok else {
            return DiskEnumeration(
                status: result.outcome.signalStatus,
                reason: "diskutil list \(result.outcome.rawValue) after \(result.durationMs) ms"
            )
        }
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let disks = dictionary["AllDisks"] as? [String]
        else {
            return DiskEnumeration(status: .error, reason: "diskutil list output did not parse")
        }
        return DiskEnumeration(status: .ok, disks: disks.filter(isWholeDiskName))
    }

    public func collect(bsd: String) -> DeviceCollection {
        let result = executor.run(.diskutilInfo(disk: bsd))

        switch result.outcome {
        case .ok:
            guard let data = result.stdout.data(using: .utf8),
                  let identity = try? DeviceCollector.parseInfoPList(data),
                  identity.bsd == bsd
            else {
                return DeviceCollection(
                    status: .error,
                    reason: "diskutil info returned output that is not the whole-disk plist for \(bsd)"
                )
            }
            return DeviceCollection(status: .ok, identity: identity)
        case .timeout:
            return DeviceCollection(
                status: .timeout,
                reason: "diskutil info \(bsd) did not answer within \(result.durationMs) ms"
            )
        case .denied:
            return DeviceCollection(status: .denied, reason: "diskutil info \(bsd) was denied")
        case .notFound:
            return DeviceCollection(status: .error, reason: "diskutil was not found")
        case .error:
            return DeviceCollection(
                status: .error,
                reason: "diskutil info \(bsd) exited \(result.exitCode.map(String.init) ?? "on a signal")"
            )
        case .policyRejected:
            return DeviceCollection(status: .error, reason: "diskutil info \(bsd) is not allow-listed")
        }
    }

    /// Parses one `diskutil info -plist` recording.
    ///
    /// Field mapping, from the recorded fixture:
    /// - `MediaName` → model; `TotalSize`/`Size`/`IOKitSize` → size_bytes
    /// - `SolidState` → media: true `ssd`, false `hdd`, absent `unknown`
    /// - `BusProtocol` → bus: `Apple Fabric` is the internal NVMe fabric, so it
    ///   maps to `nvme`; `USB`, `SATA` and `PCI-Express` lower-case directly.
    /// - `Removable`/`RemovableMedia`/`Ejectable` → removable
    public static func parseInfoPList(_ data: Data) throws -> DeviceIdentity {
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let parsed else { throw DeviceParseError.notAPlist }
        guard let plist = parsed as? [String: Any] else { throw DeviceParseError.notADictionary }
        guard let bsd = plist["DeviceIdentifier"] as? String else {
            throw DeviceParseError.missingDeviceIdentifier
        }

        let solidState = plist["SolidState"] as? Bool
        let media: String
        switch solidState {
        case .some(true): media = "ssd"
        case .some(false): media = "hdd"
        default: media = "unknown"
        }

        return DeviceIdentity(
            bsd: bsd,
            sizeBytes: integer(plist["TotalSize"]) ?? integer(plist["Size"]) ?? integer(plist["IOKitSize"]),
            model: plist["MediaName"] as? String ?? plist["IORegistryEntryName"] as? String,
            serial: plist["Serial"] as? String
                ?? plist["SerialNumber"] as? String
                ?? plist["DeviceSerialNumber"] as? String,
            media: media,
            bus: busName(from: plist["BusProtocol"] as? String, isInternal: plist["Internal"] as? Bool),
            removable: plist["Removable"] as? Bool
                ?? plist["RemovableMedia"] as? Bool
                ?? plist["Ejectable"] as? Bool,
            blockSize: integer(plist["DeviceBlockSize"]),
            internalDisk: plist["Internal"] as? Bool,
            virtualOrPhysical: plist["VirtualOrPhysical"] as? String
        )
    }
}

/// `Apple Fabric` is how the internal NVMe controller appears in
/// `BusProtocol`; the classifier's unsupported-media branch keys on `nvme`
/// (diskdoctor.md §5 step [2]).
private func busName(from protocolName: String?, isInternal: Bool?) -> String? {
    guard let protocolName else { return nil }
    let lowered = protocolName.lowercased()
    if lowered == "apple fabric" && isInternal == true {
        return "nvme"
    }
    switch lowered {
    case "pci-express", "pci express":
        return "pcie"
    default:
        return lowered
    }
}

private func integer(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}
