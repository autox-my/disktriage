import Foundation
import DiskTriageCore

/// One unified-log snapshot for a single whole disk.
public struct KernelLogCollection: Sendable, Equatable {
    public let status: SignalStatus
    public let events: [KernelLogEvent]
    public let windowHours: Int?
    public let reason: String?

    public init(
        status: SignalStatus,
        events: [KernelLogEvent] = [],
        windowHours: Int? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.events = events
        self.windowHours = windowHours
        self.reason = reason
    }
}

/// Reads the kernel's medium-error history from the unified log
/// (diskdoctor.md §4, P0 row 3/phase C).
///
/// `log show` reads the log store, not the disk under triage, so it stays fast
/// and gets the same 30 s hard timeout as every other collector. The predicate
/// is built for one BSD name; parsed events attributed to a different disk are
/// dropped, and an empty result is a measured `ok` with zero events.
public struct KernelLogCollector: Sendable {
    public static let defaultWindow = "6h"

    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
    }

    public func collect(bsd: String, window: String = KernelLogCollector.defaultWindow) -> KernelLogCollection {
        guard let hours = Self.windowHours(window) else {
            return KernelLogCollection(status: .error, reason: "unrecognised --log-window '\(window)'")
        }

        let predicate = #"eventMessage CONTAINS[c] "medium error" OR eventMessage CONTAINS[c] "I/O error" OR eventMessage CONTAINS[c] "\#(bsd)""#
        let result = executor.run(.logShow(last: window, predicate: predicate))
        guard result.outcome == .ok else {
            return KernelLogCollection(
                status: result.outcome.signalStatus,
                reason: "log show --last \(window) \(result.outcome.rawValue) after \(result.durationMs) ms"
            )
        }

        let parsed = KernelLogParser.parse(result.stdout)
        let events = parsed.events.filter { belongs($0.bsd, to: bsd) }
        return KernelLogCollection(status: .ok, events: events, windowHours: hours)
    }

    /// `--log-window` uses `log show`'s own compact forms; the SignalSet keeps
    /// whole hours, rounded up so a 30m query cannot claim 0 h.
    public static func windowHours(_ window: String) -> Int? {
        let trimmed = window.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1, let value = Int(trimmed.dropLast()), value > 0 else {
            return nil
        }
        switch trimmed.last {
        case "h": return value
        case "m": return max(1, (value + 59) / 60)
        case "d": return value * 24
        case "s": return max(1, (value + 3599) / 3600)
        default: return nil
        }
    }

    /// `disk8` owns `disk8s1`, not `disk80`. An event with no disk line is not
    /// attributed and is dropped rather than credited to this disk.
    private func belongs(_ event: String?, to bsd: String) -> Bool {
        guard let event else { return false }
        return event == bsd || event.hasPrefix(bsd + "s")
    }
}
