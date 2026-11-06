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
/// **Measured cost on this Mac (macOS 27.2, internal NVMe).** The old broad
/// predicate — `eventMessage CONTAINS[c] "medium error" OR ... "I/O error" OR
/// ... "<bsd>"` — took ~117 s for 6 h and always hit the collector's 30 s
/// limit, so triage always reported `log timeout`. Restricting the query to
/// the kernel process took ~8 s for `--last 1h` and ~50 s for `--last 6h`
/// (about 8 s per hour) and still matched every real medium-error line in the
/// Phase C capture, so the default window is 1 h.
///
/// The predicate cannot name a disk: the sense line
/// (`[External] I/O error! ... Sense Data 0x03, 0x11, 0x00`) carries no disk
/// name and the retry lines carry only the LBA. So every kernel I/O-error
/// event in the window is reported; an event whose closing `diskN: I/O error.`
/// line names another disk is dropped after parsing, while one that names the
/// queried disk — or no disk at all — is kept. `bsd` in the event names the
/// disk when a line carried one.
public struct KernelLogCollector: Sendable {
    /// The only log predicate triage may run (enforced by `CommandPolicy`).
    public static let predicate = #"process == "kernel" AND eventMessage CONTAINS[c] "I/O error""#

    public static let defaultWindow = "1h"

    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
    }

    public func collect(bsd: String, window: String = KernelLogCollector.defaultWindow) -> KernelLogCollection {
        guard let hours = Self.windowHours(window) else {
            return KernelLogCollection(status: .error, reason: "unrecognised --log-window '\(window)'")
        }

        let result = executor.run(
            .logShow(last: window, predicate: Self.predicate),
            timeout: Self.timeoutSeconds(forWindowHours: hours)
        )
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

    /// The hard timeout scales with the queried window:
    /// `max(30 s, 12 s x hours + 15 s)`. The measured cost is ~8 s per hour,
    /// so 12 s per hour leaves headroom: 1 h -> 30 s, 6 h -> 87 s, 24 h -> 303 s.
    public static func timeoutSeconds(forWindowHours hours: Int) -> TimeInterval {
        max(30, 12 * Double(hours) + 15)
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

    /// `disk8` owns `disk8s1`, not `disk80`. An event with no disk line cannot
    /// be attributed either way and is kept: the sense line carries no disk
    /// name, so dropping it would lose the real evidence.
    private func belongs(_ event: String?, to bsd: String) -> Bool {
        guard let event else { return true }
        return event == bsd || event.hasPrefix(bsd + "s")
    }
}
