import Foundation
import DiskTriageCore

/// One whole-disk I/O snapshot plus the status it was collected with.
public struct IOCollection: Sendable, Equatable {
    public let status: SignalStatus
    public let counters: IORegCounters?
    public let reason: String?

    public init(status: SignalStatus, counters: IORegCounters? = nil, reason: String? = nil) {
        self.status = status
        self.counters = counters
        self.reason = reason
    }
}

/// I/O error counters from IORegistry (diskdoctor.md §4, P0 row 2).
///
/// Two read-only queries answer one section: the Statistics capture names the
/// driver's child IOMedia by registry id, and the IOMedia capture maps that id
/// to the `BSD Name`. When either half is absent the association is unknown
/// and the section is `unsupported` with the reason; it is never guessed.
public struct IOStatsCollector: Sendable {
    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
    }

    public func collect(bsd: String) -> IOCollection {
        let statistics = executor.run(.ioregStatistics)
        guard statistics.outcome == .ok else {
            return IOCollection(
                status: statistics.outcome.signalStatus,
                reason: "ioreg Statistics \(bsd) \(statistics.outcome.rawValue) after \(statistics.durationMs) ms"
            )
        }
        guard let parsed = try? IORegStatisticsParser.parse(statistics.stdout) else {
            return IOCollection(status: .error, reason: "ioreg Statistics output did not parse")
        }
        guard !parsed.drivers.isEmpty else {
            return IOCollection(status: .unsupported, reason: "ioreg reported no IOBlockStorageDriver")
        }

        let mediaResult = executor.run(.ioregMedia)
        guard mediaResult.outcome == .ok else {
            return IOCollection(
                status: mediaResult.outcome.signalStatus,
                reason: "ioreg IOMedia \(bsd) \(mediaResult.outcome.rawValue) after \(mediaResult.durationMs) ms"
            )
        }
        guard let media = try? IORegMediaParser.parse(mediaResult.stdout) else {
            return IOCollection(status: .error, reason: "ioreg IOMedia output did not parse")
        }
        guard let driver = parsed.driver(forBSD: bsd, media: media) else {
            return IOCollection(
                status: .unsupported,
                reason: "no IOMedia entry maps \(bsd) to an IORegistry driver; the association is unknown"
            )
        }
        return IOCollection(status: .ok, counters: driver.counters)
    }
}
