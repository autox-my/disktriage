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
    public private(set) var smart: SmartSignals?
    public private(set) var io: IOSignals?
    public private(set) var log: LogSignals?
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

    /// Installs the I/O section from one driver's counter delta.
    ///
    /// `timeouts` stays nil: ioreg exposes no timeouts counter (P0 phase B).
    /// `p0_validated` stays absent unless a caller explicitly passes it, so the
    /// counters are displayed but not counted (REQ-0029).
    public mutating func setIO(_ delta: IORegDriverDelta, p0Validated: Bool? = nil) {
        io = IOSignals(
            status: .ok,
            retries: delta.counters.retriesRead.map(Int.init),
            errors: delta.counters.errorsRead.map(Int.init),
            timeouts: nil,
            p0Validated: p0Validated
        )
        unsupportedReasons.removeValue(forKey: "io")
    }

    /// Installs the I/O section from a live whole-disk snapshot. A non-ok
    /// status keeps its reason and carries no counters.
    public mutating func setIO(_ collection: IOCollection) {
        io = IOSignals(
            status: collection.status,
            retries: collection.counters?.retriesRead.map(Int.init),
            errors: collection.counters?.errorsRead.map(Int.init),
            timeouts: nil,
            p0Validated: nil
        )
        if collection.status == .ok {
            unsupportedReasons.removeValue(forKey: "io")
        } else {
            unsupportedReasons["io"] = collection.reason ?? "ioreg did not return a usable snapshot"
        }
    }

    /// Installs the SMART section. Only `ok` makes the counters measurements;
    /// `unsupported`, `timeout` and `denied` keep nil counters (REQ-0023).
    public mutating func setSmart(_ collection: SmartCollection) {
        smart = collection.signals
        if collection.status == .ok {
            unsupportedReasons.removeValue(forKey: "smart")
        } else {
            unsupportedReasons["smart"] = collection.reason ?? "smartctl did not return a usable recording"
        }
    }

    /// Installs the log section from parsed kernel events and the `--last`
    /// window the query used. A measured empty event list is `ok`, not absent.
    public mutating func setLog(_ events: [KernelLogEvent], windowHours: Int) {
        log = LogSignals(status: .ok, windowHours: windowHours, events: mapped(events))
        unsupportedReasons.removeValue(forKey: "log")
    }

    /// Installs a live log collection. A timeout or denial keeps its status
    /// and has no window and no events.
    public mutating func setLog(_ collection: KernelLogCollection) {
        if collection.status == .ok {
            log = LogSignals(
                status: .ok,
                windowHours: collection.windowHours,
                events: mapped(collection.events)
            )
            unsupportedReasons.removeValue(forKey: "log")
        } else {
            log = LogSignals(status: collection.status)
            unsupportedReasons["log"] = collection.reason ?? "log show did not return a usable recording"
        }
    }

    private func mapped(_ events: [KernelLogEvent]) -> [LogEvent] {
        events.compactMap { event -> LogEvent? in
            guard let lba = event.lba else { return nil }
            return LogEvent(
                time: event.lastTime,
                firstTime: event.firstTime,
                kind: event.kind,
                lba: lba,
                count: event.occurrences,
                senseKey: event.senseKey,
                retry: event.maxRetry
            )
        }
    }

    public func build() throws -> SignalSet {
        var object: [String: Any] = [
            "schema_version": DiskTriageCoreInfo.supportedSchemaVersion,
            "collected_at": iso8601(collectedAt),
        ]

        object["device"] = deviceSection()
        object["smart"] = smartSection()
        object["io"] = ioSection()
        object["log"] = logSection()
        for section in ["drivers", "fs"] {
            object[section] = ["status": SignalStatus.unsupported.rawValue] as [String: Any]
        }

        var notes: [[String: Any]] = []
        for section in SignalSetBuilder.sectionNames {
            let collector = SignalSetBuilder.collectorNames[section] ?? section
            let outcome = sectionOutcome(section)
            if section == "device", outcome == .ok {
                continue
            }
            notes.append([
                "collector": collector,
                "outcome": outcome.rawValue,
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

    private func sectionOutcome(_ section: String) -> SignalStatus {
        switch section {
        case "device": return device?.status ?? .unsupported
        case "smart": return smart?.status ?? .unsupported
        case "io": return io?.status ?? .unsupported
        case "log": return log?.status ?? .unsupported
        default: return .unsupported
        }
    }

    private func smartSection() -> [String: Any] {
        guard let smart else {
            return ["status": SignalStatus.unsupported.rawValue]
        }
        guard smart.status == .ok else {
            return ["status": smart.status.rawValue]
        }

        var section: [String: Any] = ["status": SignalStatus.ok.rawValue]
        if let overall = smart.overall { section["overall"] = overall }
        if let pending = smart.pending { section["pending"] = pending }
        if let reallocated = smart.reallocated { section["reallocated"] = reallocated }
        if let uncorrectable = smart.uncorrectable { section["uncorrectable"] = uncorrectable }
        if let hours = smart.powerOnHours { section["power_on_hours"] = hours }
        if let raw = smart.rawReadErrors { section["raw_read_errors"] = raw }
        if let errorLog = smart.errorLog {
            section["error_log"] = errorLog.map { error -> [String: Any] in
                var item: [String: Any] = [:]
                if let lba = error.lba { item["lba"] = lba }
                if let type = error.type { item["type"] = type }
                if let count = error.count { item["count"] = count }
                return item
            }
        }
        if let selfTest = smart.selfTest {
            var item: [String: Any] = [:]
            if let last = selfTest.last { item["last"] = last }
            if let age = selfTest.ageHours { item["age_hours"] = age }
            section["self_test"] = item
        }
        // First sight of a drive: an explicit null, never an invented snapshot.
        section["history"] = smart.history.map { history -> [String: Any] in
            var item: [String: Any] = [:]
            if let recorded = history.recordedAt { item["recorded_at"] = iso8601(recorded) }
            if let pending = history.pending { item["pending"] = pending }
            if let reallocated = history.reallocated { item["reallocated"] = reallocated }
            return item
        } ?? NSNull()
        return section
    }

    private func ioSection() -> [String: Any] {
        guard let io else {
            return ["status": SignalStatus.unsupported.rawValue]
        }
        var section: [String: Any] = ["status": io.status.rawValue]
        if let retries = io.retries { section["retries"] = retries }
        if let errors = io.errors { section["errors"] = errors }
        if let timeouts = io.timeouts { section["timeouts"] = timeouts }
        if let validated = io.p0Validated { section["p0_validated"] = validated }
        return section
    }

    private func logSection() -> [String: Any] {
        guard let log else {
            return ["status": SignalStatus.unsupported.rawValue]
        }
        var section: [String: Any] = ["status": log.status.rawValue]
        if let window = log.windowHours { section["window_hours"] = window }
        if let events = log.events {
            section["events"] = events.map { event -> [String: Any] in
                var item: [String: Any] = [:]
                if let time = event.time { item["time"] = iso8601(time) }
                if let first = event.firstTime { item["first_time"] = iso8601(first) }
                if let kind = event.kind { item["kind"] = kind }
                if let lba = event.lba { item["lba"] = lba }
                if let count = event.count { item["count"] = count }
                if let senseKey = event.senseKey { item["sense_key"] = senseKey }
                if let retry = event.retry { item["retry"] = retry }
                return item
            }
        }
        return section
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
