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
    /// True for a fixture that carries a prior SMART snapshot that was not
    /// recorded from a real drive. Never true for a live capture.
    public let synthetic: Bool?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case collectedAt = "collected_at"
        case device, smart, io, log, drivers, permissions, fs, symptoms, synthetic
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

    public init(
        status: SignalStatus,
        overall: String? = nil,
        pending: Int? = nil,
        reallocated: Int? = nil,
        uncorrectable: Int? = nil,
        powerOnHours: Int? = nil,
        rawReadErrors: Int? = nil,
        errorLog: [SmartError]? = nil,
        selfTest: SmartSelfTest? = nil,
        history: SmartHistory? = nil
    ) {
        self.status = status
        self.overall = overall
        self.pending = pending
        self.reallocated = reallocated
        self.uncorrectable = uncorrectable
        self.powerOnHours = powerOnHours
        self.rawReadErrors = rawReadErrors
        self.errorLog = errorLog
        self.selfTest = selfTest
        self.history = history
    }

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

    public init(last: String? = nil, ageHours: Int? = nil) {
        self.last = last
        self.ageHours = ageHours
    }

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

    public init(recordedAt: Date? = nil, pending: Int? = nil, reallocated: Int? = nil) {
        self.recordedAt = recordedAt
        self.pending = pending
        self.reallocated = reallocated
    }

    enum CodingKeys: String, CodingKey {
        case recordedAt = "recorded_at"
        case pending, reallocated
    }
}

public struct IOSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let retries: Int?
    /// `Errors (Read)` from ioreg. P0 phase C measured this moving 0 -> 1 while
    /// `Retries` stayed 0, so the two are distinct signals (diskdoctor.md §4).
    public let errors: Int?
    public let timeouts: Int?
    /// P0 item 2: only a validated counter set may count as an independent
    /// evidence source (diskdoctor.md §5). Absent or false means displayed,
    /// not counted.
    public let p0Validated: Bool?

    public init(
        status: SignalStatus,
        retries: Int? = nil,
        errors: Int? = nil,
        timeouts: Int? = nil,
        p0Validated: Bool? = nil
    ) {
        self.status = status
        self.retries = retries
        self.errors = errors
        self.timeouts = timeouts
        self.p0Validated = p0Validated
    }

    enum CodingKeys: String, CodingKey {
        case status, retries, errors, timeouts
        case p0Validated = "p0_validated"
    }
}

public struct LogSignals: Codable, Equatable, Sendable {
    public let status: SignalStatus
    public let windowHours: Int?
    public let events: [LogEvent]?

    public init(status: SignalStatus, windowHours: Int? = nil, events: [LogEvent]? = nil) {
        self.status = status
        self.windowHours = windowHours
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case status, events
        case windowHours = "window_hours"
    }
}

public struct LogEvent: Codable, Equatable, Sendable {
    public let time: Date?
    /// First occurrence in the same burst, when the collector can supply it;
    /// the renderer shows the window as `first–last`.
    public let firstTime: Date?
    public let kind: String?
    public let lba: Int?
    public let count: Int?
    /// SCSI sense key from the kernel's `Sense Data` line (3 = MEDIUM ERROR).
    public let senseKey: Int?
    /// Highest retry number in the burst; the kernel retries about every 2.2 s.
    public let retry: Int?

    public init(
        time: Date?,
        firstTime: Date? = nil,
        kind: String? = nil,
        lba: Int? = nil,
        count: Int? = nil,
        senseKey: Int? = nil,
        retry: Int? = nil
    ) {
        self.time = time
        self.firstTime = firstTime
        self.kind = kind
        self.lba = lba
        self.count = count
        self.senseKey = senseKey
        self.retry = retry
    }

    enum CodingKeys: String, CodingKey {
        case time, kind, lba, count, retry
        case firstTime = "first_time"
        case senseKey = "sense_key"
    }
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

public extension JSONEncoder {
    /// The canonical encoder for a `SignalSet` or a snapshot record: ISO-8601
    /// timestamps, so a snapshot's date means the same on write and read.
    static func disktriage() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension SignalSet {
    /// A copy safe to commit as a fixture: the device serial is replaced by
    /// the caller's hash and every measurement is preserved (REQ-0060).
    ///
    /// The schema carries no UUID or volume-name field; a `nil` serial is left
    /// alone rather than inventing a value.
    func redacted(serialHash: (String) -> String) -> SignalSet {
        guard let device, let serial = device.serial, !serial.isEmpty else {
            return self
        }
        let redactedDevice = DeviceSignals(
            status: device.status,
            bsd: device.bsd,
            sizeBytes: device.sizeBytes,
            model: device.model,
            serial: serialHash(serial),
            media: device.media,
            bus: device.bus,
            bridge: device.bridge,
            satPassthrough: device.satPassthrough,
            removable: device.removable
        )
        return SignalSet(
            schemaVersion: schemaVersion,
            collectedAt: collectedAt,
            device: redactedDevice,
            smart: smart,
            io: io,
            log: log,
            drivers: drivers,
            permissions: permissions,
            fs: fs,
            symptoms: symptoms,
            collectorNotes: collectorNotes,
            synthetic: synthetic
        )
    }

    /// Returns the same set with `smart.history` attached from a local snapshot.
    ///
    /// A history is only meaningful beside a measured SMART section; when SMART
    /// is not `ok` this returns the set unchanged, so a bridge that hides SMART
    /// can never show a trend from an older reading (diskdoctor.md §4, §5).
    func attachingSmartHistory(_ history: SmartHistory?) -> SignalSet {
        guard let smart, smart.status == .ok, let history else { return self }
        let updated = SmartSignals(
            status: smart.status,
            overall: smart.overall,
            pending: smart.pending,
            reallocated: smart.reallocated,
            uncorrectable: smart.uncorrectable,
            powerOnHours: smart.powerOnHours,
            rawReadErrors: smart.rawReadErrors,
            errorLog: smart.errorLog,
            selfTest: smart.selfTest,
            history: history
        )
        return SignalSet(
            schemaVersion: schemaVersion,
            collectedAt: collectedAt,
            device: device,
            smart: updated,
            io: io,
            log: log,
            drivers: drivers,
            permissions: permissions,
            fs: fs,
            symptoms: symptoms,
            collectorNotes: collectorNotes,
            synthetic: synthetic
        )
    }
}
