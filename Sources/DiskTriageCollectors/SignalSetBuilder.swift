import Foundation
import DiskTriageCore

public enum SignalSetBuilderError: Error, Equatable {
    case cannotEncode
}

/// Assembles collector results into a `SignalSet` (diskdoctor.md §3).
///
/// Every section is emitted with a status. A section that was not collected is
/// `unsupported` with a reason; it is never absent and never a zero. The
/// reason is kept in `unsupportedReasons` because schema v1 has no per-section
/// reason field (see docs/collectors-observations.md).
public struct SignalSetBuilder: Sendable {
    public let collectedAt: Date
    public private(set) var device: DeviceCollection?
    public private(set) var unsupportedReasons: [String: String]

    private static let sectionNames = ["device", "smart", "io", "log", "drivers", "fs"]

    /// Section → collector name, matching the `collector_notes` vocabulary in
    /// the plan's SignalSet example.
    private static let collectorNames: [String: String] = [
        "device": "diskutil",
        "smart": "smartctl",
        "io": "ioreg",
        "log": "unified-log",
        "drivers": "filesystem-drivers",
        "fs": "filesystem",
    ]

    public init(collectedAt: Date = Date()) {
        self.collectedAt = collectedAt
        self.unsupportedReasons = [
            "device": "the device collector has not run",
            "smart": "no SMART collector until bench Phase B records USB-HDD output",
            "io": "no I/O-statistics collector until bench Phase B records ioreg output",
            "log": "no unified-log parser until bench Phase B records a medium-error record",
            "drivers": "no filesystem-driver inventory collector yet",
            "fs": "filesystem inspection happens on the image, not on the device",
        ]
    }

    /// Installs the device section. A timeout, denial or error keeps its own
    /// status and carries no counters.
    public mutating func setDevice(_ collection: DeviceCollection) {
        device = collection
        if collection.status == .ok, collection.identity != nil {
            unsupportedReasons.removeValue(forKey: "device")
        } else {
            unsupportedReasons["device"] = collection.reason ?? "the device collector did not return a recording"
        }
    }

    /// Marks a section as not collected, recording why.
    public mutating func markUnsupported(section: String, reason: String) {
        unsupportedReasons[section] = reason
    }

    public func build() throws -> SignalSet {
        var object: [String: Any] = [
            "schema_version": DiskTriageCoreInfo.supportedSchemaVersion,
            "collected_at": iso8601(collectedAt),
        ]

        object["device"] = deviceSection()
        for section in ["smart", "io", "log", "drivers", "fs"] {
            object[section] = ["status": SignalStatus.unsupported.rawValue] as [String: Any]
        }

        var notes: [[String: Any]] = []
        for section in SignalSetBuilder.sectionNames {
            let collector = SignalSetBuilder.collectorNames[section] ?? section
            if section == "device", let device, device.status == .ok {
                continue
            }
            if section == "device", let device {
                notes.append([
                    "collector": collector,
                    "outcome": device.status.rawValue,
                ])
                continue
            }
            notes.append([
                "collector": collector,
                "outcome": SignalStatus.unsupported.rawValue,
            ])
        }
        object["collector_notes"] = notes

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let signals = try? JSONDecoder.disktriage().decode(SignalSet.self, from: data)
        else {
            throw SignalSetBuilderError.cannotEncode
        }
        return signals
    }

    private func deviceSection() -> [String: Any] {
        guard let device else {
            return ["status": SignalStatus.unsupported.rawValue]
        }
        guard device.status == .ok, let identity = device.identity else {
            return ["status": device.status.rawValue]
        }

        var section: [String: Any] = [
            "status": SignalStatus.ok.rawValue,
            "bsd": identity.bsd,
            "media": identity.media,
        ]
        if let size = identity.sizeBytes { section["size_bytes"] = size }
        if let model = identity.model { section["model"] = model }
        if let serial = identity.serial { section["serial"] = serial }
        if let bus = identity.bus { section["bus"] = bus }
        if let removable = identity.removable { section["removable"] = removable }
        return section
    }
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
