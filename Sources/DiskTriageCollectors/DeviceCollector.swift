import Foundation
import DiskTriageCore

/// The identity fields `diskutil info -plist` actually exposes for a whole
/// disk. `serial` is `nil` on this build's internal NVMe, which is a fact about
/// the recording, not an empty string.
public struct DeviceIdentity: Sendable, Equatable {
    public let bsd: String
    public let sizeBytes: Int64?
    public let model: String?
    /// `Vendor Name` from the ioreg device tree; diskutil's plist has no
    /// equivalent field.
    public let vendor: String?
    public let serial: String?
    /// `hdd`, `ssd` or `unknown` (diskdoctor.md §5 step [2]).
    public let media: String
    /// `usb`, `sata`, `nvme`, … after the `BusProtocol` mapping below.
    public let bus: String?
    public let removable: Bool?
    /// IOMedia's `Ejectable`, when the ioreg path supplies it.
    public let ejectable: Bool?
    public let blockSize: Int64?
    public let internalDisk: Bool?
    /// `Virtual`, `Physical` or `Unknown` from `diskutil info -plist`. The
    /// internal Apple NVMe reports `Unknown`; synthesized APFS containers and
    /// disk images report `Virtual`, which `list` filters out. The ioreg path
    /// leaves it nil: the registry has no such field, and absent is not a
    /// guess.
    public let virtualOrPhysical: String?

    public init(
        bsd: String,
        sizeBytes: Int64? = nil,
        model: String? = nil,
        vendor: String? = nil,
        serial: String? = nil,
        media: String = "unknown",
        bus: String? = nil,
        removable: Bool? = nil,
        ejectable: Bool? = nil,
        blockSize: Int64? = nil,
        internalDisk: Bool? = nil,
        virtualOrPhysical: String? = nil
    ) {
        self.bsd = bsd
        self.sizeBytes = sizeBytes
        self.model = model
        self.vendor = vendor
        self.serial = serial
        self.media = media
        self.bus = bus
        self.removable = removable
        self.ejectable = ejectable
        self.blockSize = blockSize
        self.internalDisk = internalDisk
        self.virtualOrPhysical = virtualOrPhysical
    }
}

/// Which command produced the identity. `diskutil` is the normal path; `ioreg`
/// is the path that keeps working while DiskArbitration is stopped, and the
/// fallback when `diskutil` times out.
public enum DeviceCollectionSource: String, Sendable, Equatable {
    case diskutil
    case ioreg
}

/// One device section plus the status it was collected with.
public struct DeviceCollection: Sendable, Equatable {
    public let status: SignalStatus
    public let identity: DeviceIdentity?
    public let reason: String?
    public let source: DeviceCollectionSource?
    /// The `diskutil info` timeout that forced an ioreg fallback, when one
    /// did. A timeout is evidence and must not disappear when the fallback
    /// succeeds.
    public let diskutilTimeoutMs: Int?

    public init(
        status: SignalStatus,
        identity: DeviceIdentity? = nil,
        reason: String? = nil,
        source: DeviceCollectionSource? = nil,
        diskutilTimeoutMs: Int? = nil
    ) {
        self.status = status
        self.identity = identity
        self.reason = reason
        self.source = source
        self.diskutilTimeoutMs = diskutilTimeoutMs
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
    private let diskArbitration: DiskArbitrationProbe

    public init(
        executor: any CommandExecuting = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executor = executor
        self.diskArbitration = DiskArbitrationProbe(executor: executor, environment: environment)
    }

    /// `[0] enumerate` for the decision tree: whole disks only, never slices.
    public func enumerateWholeDisks() -> [String] {
        enumerate().disks
    }

    /// Enumeration that keeps its status: an empty list from a failed command
    /// is not "no disks attached" (diskdoctor.md §2.3).
    ///
    /// While DiskArbitration is stopped the list comes from ioreg; a `diskutil
    /// list` timeout falls back the same way once, because a hung enumeration
    /// must not block triage or the internal-disk probe.
    public func enumerate() -> DiskEnumeration {
        if let reason = diskArbitration.diskutilSkipReason() {
            return enumerateFromIOReg(reason: reason)
        }

        let result = executor.run(.diskutilList)
        guard result.outcome == .ok else {
            if result.outcome == .timeout {
                return enumerateFromIOReg(
                    reason: "diskutil list timed out after \(result.durationMs) ms; disks read from ioreg"
                )
            }
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

    /// The never-`diskutil` enumeration: whole media in the registry tree.
    private func enumerateFromIOReg(reason: String) -> DiskEnumeration {
        let result = executor.run(.ioregDeviceTree)
        guard result.outcome == .ok else {
            return DiskEnumeration(
                status: result.outcome.signalStatus,
                reason: reason + "; ioreg device tree \(result.outcome.rawValue) after \(result.durationMs) ms"
            )
        }
        let disks = IORegDeviceParser.wholeDisks(result.stdout).map(\.bsd)
        guard !disks.isEmpty else {
            return DiskEnumeration(status: .error, reason: reason + "; ioreg device tree lists no whole disk")
        }
        // diskutil lists diskN in numeric order; the registry tree is in
        // parent-first order (disk0, disk1, disk3, disk2, …). Sort so `list`
        // reads the same either way.
        let sorted = disks.sorted { wholeDiskUnit($0) < wholeDiskUnit($1) }
        return DiskEnumeration(status: .ok, disks: sorted, reason: reason)
    }

    public func collect(bsd: String) -> DeviceCollection {
        if let reason = diskArbitration.diskutilSkipReason() {
            return collectFromIOReg(bsd: bsd, reason: reason, diskutilTimeoutMs: nil)
        }

        let result = executor.run(.diskutilInfo(disk: bsd))

        switch result.outcome {
        case .ok:
            guard let data = result.stdout.data(using: .utf8),
                  let identity = try? DeviceCollector.parseInfoPList(data),
                  identity.bsd == bsd
            else {
                return DeviceCollection(
                    status: .error,
                    reason: "diskutil info returned output that is not the whole-disk plist for \(bsd)",
                    source: .diskutil
                )
            }
            return DeviceCollection(status: .ok, identity: identity, source: .diskutil)
        case .timeout:
            // `diskutil` can also time out because the disk is failing, not
            // only because DiskArbitration is stopped. The timeout stays as
            // evidence, and one ioreg attempt is allowed.
            return collectFromIOReg(
                bsd: bsd,
                reason: "diskutil info \(bsd) timed out after \(result.durationMs) ms; identity read from ioreg",
                diskutilTimeoutMs: result.durationMs
            )
        case .denied:
            return DeviceCollection(
                status: .denied,
                reason: "diskutil info \(bsd) was denied",
                source: .diskutil
            )
        case .notFound:
            return DeviceCollection(
                status: .error,
                reason: "diskutil was not found",
                source: .diskutil
            )
        case .error:
            return DeviceCollection(
                status: .error,
                reason: "diskutil info \(bsd) exited \(result.exitCode.map(String.init) ?? "on a signal")",
                source: .diskutil
            )
        case .policyRejected:
            return DeviceCollection(
                status: .error,
                reason: "diskutil info \(bsd) is not allow-listed",
                source: .diskutil
            )
        }
    }

    /// The identity path that never calls `diskutil`. Both the stopped-daemon
    /// path and the timeout fallback land here.
    private func collectFromIOReg(
        bsd: String,
        reason: String,
        diskutilTimeoutMs: Int?
    ) -> DeviceCollection {
        let result = executor.run(.ioregDeviceTree)
        guard result.outcome == .ok else {
            return DeviceCollection(
                status: result.outcome.signalStatus,
                reason: reason + "; ioreg device tree \(result.outcome.rawValue) after \(result.durationMs) ms",
                source: .ioreg,
                diskutilTimeoutMs: diskutilTimeoutMs
            )
        }
        guard let parsed = IORegDeviceParser.parse(result.stdout, bsd: bsd) else {
            return DeviceCollection(
                status: .error,
                reason: reason + "; ioreg device tree has no whole disk \(bsd)",
                source: .ioreg,
                diskutilTimeoutMs: diskutilTimeoutMs
            )
        }

        // A USB bridge can hide the serial on the block device while the USB
        // host device still exposes it. One extra, small query, and only when
        // the serial is missing: the association is the same BSD name in the
        // same subtree, never a guess by order.
        var serial = parsed.serial
        if serial == nil {
            let usb = executor.run(.ioregUSBDeviceTree)
            if usb.outcome == .ok,
               let usbIdentity = IORegDeviceParser.parse(usb.stdout, bsd: bsd) {
                serial = usbIdentity.serial
            }
        }

        let identity = DeviceIdentity(
            bsd: parsed.bsd,
            sizeBytes: parsed.sizeBytes,
            model: parsed.model,
            vendor: parsed.vendor,
            serial: serial,
            media: parsed.media ?? "unknown",
            bus: parsed.bus,
            removable: parsed.removable,
            ejectable: parsed.ejectable,
            blockSize: parsed.blockSize,
            internalDisk: parsed.internalDisk,
            virtualOrPhysical: parsed.virtual == true ? "Virtual" : nil
        )
        return DeviceCollection(
            status: .ok,
            identity: identity,
            reason: reason,
            source: .ioreg,
            diskutilTimeoutMs: diskutilTimeoutMs
        )
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
            vendor: nil,
            serial: plist["Serial"] as? String
                ?? plist["SerialNumber"] as? String
                ?? plist["DeviceSerialNumber"] as? String,
            media: media,
            bus: busName(from: plist["BusProtocol"] as? String, isInternal: plist["Internal"] as? Bool),
            removable: plist["Removable"] as? Bool
                ?? plist["RemovableMedia"] as? Bool
                ?? plist["Ejectable"] as? Bool,
            ejectable: plist["Ejectable"] as? Bool,
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
    StorageBus.name(fromInterconnect: protocolName, isInternal: isInternal)
}

private func integer(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}

/// `disk3` → 3; used only to match `diskutil list`'s ordering.
private func wholeDiskUnit(_ name: String) -> Int {
    Int(name.dropFirst(4)) ?? Int.max
}
