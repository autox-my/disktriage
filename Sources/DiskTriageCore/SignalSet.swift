import Foundation

/// The status of one section of a `SignalSet`.
///
/// An absent signal is never a zero: `denied`, `timeout` and `unsupported` all
/// mean "no value", and only `ok` lets a counter be read as a measurement
/// (diskdoctor.md §2.3, §3).
public enum SignalStatus: String, Codable, Sendable, CaseIterable {
    case ok
    case denied
    case unsupported
    case timeout
    case error
}

/// Permission state recorded by the collector, not inferred by the tool
/// (diskdoctor.md §7).
public enum AccessState: String, Codable, Sendable, CaseIterable {
    case granted
    case denied
}

/// A recorded set of hardware signals: the contract between collectors and the
/// classifier (diskdoctor.md §3).
///
/// Rules: versioned; every collected section carries a `status`; counters are
/// optional so that "unknown" decodes as `nil`, never `0`; timestamps are UTC.
public struct SignalSet: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let collectedAt: Date
    public let device: DeviceSignals?
    public let smart: SmartSignals?
    public let io: IOSignals?
    public let log: LogSignals?
    public let drivers: DriverSignals?
    public let permissions: PermissionSignals?
    public let fs: FileSystemSignals?
    public let symptoms: SymptomSignals?
    public let collectorNotes: [CollectorNote]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case collectedAt = "collected_at"
        case device, smart, io, log, drivers, permissions, fs, symptoms
        case collectorNotes = "collector_notes"
    }
}

public struct DeviceSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let bsd: String?
    public let sizeBytes: Int64?
    public let model: String?
    public let serial: String?
    public let media: String?
    public let bus: String?
    public let bridge: String?
    public let satPassthrough: String?
    public let removable: Bool?

    enum CodingKeys: String, CodingKey {
        case status, bsd, model, serial, media, bus, bridge, removable
        case sizeBytes = "size_bytes"
        case satPassthrough = "sat_passthrough"
    }
}

public struct SmartSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let overall: String?
    public let pending: Int?
    public let reallocated: Int?
    public let uncorrectable: Int?
    public let powerOnHours: Int?
    public let rawReadErrors: Int?
    public let errorLog: [SmartError]?
    public let selfTest: SmartSelfTest?
    /// `nil` on the first sight of a drive; trend rules never fire without a
    /// real prior snapshot (diskdoctor.md §3, §5).
    public let history: SmartHistory?

    enum CodingKeys: String, CodingKey {
        case status, overall, pending, reallocated, uncorrectable, history
        case powerOnHours = "power_on_hours"
        case rawReadErrors = "raw_read_errors"
        case errorLog = "error_log"
        case selfTest = "self_test"
    }
}

public struct SmartError: Codable, Equatable, Sendable {
    public let lba: Int?
    public let type: String?
    public let count: Int?
}

public struct SmartSelfTest: Codable, Equatable, Sendable {
    public let last: String?
    public let ageHours: Int?

    enum CodingKeys: String, CodingKey {
        case last
        case ageHours = "age_hours"
    }
}

/// A locally recorded snapshot, keyed by hashed serial. The full shape is
/// frozen with the snapshot store in P1; fixtures must not invent one.
public struct SmartHistory: Codable, Equatable, Sendable {
    public let recordedAt: Date?
    public let pending: Int?
    public let reallocated: Int?

    enum CodingKeys: String, CodingKey {
        case recordedAt = "recorded_at"
        case pending, reallocated
    }
}

public struct IOSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let retries: Int?
    public let timeouts: Int?
}

public struct LogSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let windowHours: Int?
    public let events: [LogEvent]?

    enum CodingKeys: String, CodingKey {
        case status, events
        case windowHours = "window_hours"
    }
}

public struct LogEvent: Codable, Equatable, Sendable {
    public let time: Date?
    public let kind: String?
    public let lba: Int?
    public let count: Int?
}

public struct DriverSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let items: [DriverItem]?
}

public struct DriverItem: Codable, Equatable, Sendable {
    public let path: String?
    public let thirdParty: Bool?
    public let claims: [String]?

    enum CodingKeys: String, CodingKey {
        case path, claims
        case thirdParty = "third_party"
    }
}

/// Not a collected section: these are probe results, so there is no section
/// `status` (diskdoctor.md §7).
public struct PermissionSignals: Codable, Equatable, Sendable {
    public let root: Bool?
    public let rawRead: AccessState?
    public let removableVolumes: AccessState?

    enum CodingKeys: String, CodingKey {
        case root
        case rawRead = "raw_read"
        case removableVolumes = "removable_volumes"
    }
}

public struct FileSystemSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let type: String?
    public let partitionStartLba: Int?
    public let mounted: Bool?
    public let readable: Bool?

    enum CodingKeys: String, CodingKey {
        case status, type, mounted, readable
        case partitionStartLba = "partition_start_lba"
    }
}

/// What software cannot observe, supplied by the user (diskdoctor.md §3).
public struct SymptomSignals: Codable, Equatable, Sendable {
    public let source: String?
    public let clicking: Bool?
    public let disappears: Bool?
    public let worksOnOtherPort: Bool?
    public let worksWithOtherCable: Bool?
    public let worksWithOtherEnclosure: Bool?

    enum CodingKeys: String, CodingKey {
        case source, clicking, disappears
        case worksOnOtherPort = "works_on_other_port"
        case worksWithOtherCable = "works_with_other_cable"
        case worksWithOtherEnclosure = "works_with_other_enclosure"
    }
}

public struct CollectorNote: Codable, Equatable, Sendable {
    public let collector: String?
    public let outcome: SignalStatus?
    public let afterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case collector, outcome
        case afterSeconds = "after_s"
    }
}

public extension JSONDecoder {
    /// The canonical decoder for a `SignalSet`: ISO-8601 timestamps, UTC only.
    /// Collectors, fixtures and the CLI share this so a date never changes
    /// meaning between them.
    static func disktriage() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
