import Foundation

/// The per-driver counters `ioreg -r -c IOBlockStorageDriver -k Statistics`
/// exposes (diskdoctor.md §4, P0 row 2). Every counter is optional: a key the
/// output did not carry is unknown, never zero.
public struct IORegCounters: Equatable, Sendable {
    public let bytesRead: Int64?
    public let bytesWritten: Int64?
    public let operationsRead: Int64?
    public let operationsWritten: Int64?
    public let errorsRead: Int64?
    public let errorsWritten: Int64?
    public let retriesRead: Int64?
    public let retriesWritten: Int64?
    public let totalTimeRead: Int64?
    public let totalTimeWrite: Int64?

    public init(
        bytesRead: Int64? = nil,
        bytesWritten: Int64? = nil,
        operationsRead: Int64? = nil,
        operationsWritten: Int64? = nil,
        errorsRead: Int64? = nil,
        errorsWritten: Int64? = nil,
        retriesRead: Int64? = nil,
        retriesWritten: Int64? = nil,
        totalTimeRead: Int64? = nil,
        totalTimeWrite: Int64? = nil
    ) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.operationsRead = operationsRead
        self.operationsWritten = operationsWritten
        self.errorsRead = errorsRead
        self.errorsWritten = errorsWritten
        self.retriesRead = retriesRead
        self.retriesWritten = retriesWritten
        self.totalTimeRead = totalTimeRead
        self.totalTimeWrite = totalTimeWrite
    }

    static func subtracting(_ before: IORegCounters, from after: IORegCounters) -> IORegCounters {
        IORegCounters(
            bytesRead: difference(before.bytesRead, after.bytesRead),
            bytesWritten: difference(before.bytesWritten, after.bytesWritten),
            operationsRead: difference(before.operationsRead, after.operationsRead),
            operationsWritten: difference(before.operationsWritten, after.operationsWritten),
            errorsRead: difference(before.errorsRead, after.errorsRead),
            errorsWritten: difference(before.errorsWritten, after.errorsWritten),
            retriesRead: difference(before.retriesRead, after.retriesRead),
            retriesWritten: difference(before.retriesWritten, after.retriesWritten),
            totalTimeRead: difference(before.totalTimeRead, after.totalTimeRead),
            totalTimeWrite: difference(before.totalTimeWrite, after.totalTimeWrite)
        )
    }
}

/// One `IOBlockStorageDriver` node and the `Statistics` block nested under it.
///
/// The `-k Statistics` output identifies the driver by its IORegistry node id
/// and its first child `IOMedia` by name, but it does **not** carry the child's
/// `BSD Name`. So `bsdName` is nil for the real captures and the driver cannot
/// be associated with `diskN` from this output alone. The extra query is
/// `ioreg -r -c IOMedia -d 1 -w 0` (recorded in docs/p0-runbook.md), which
/// supplies `BSD Name`; mapping it to the driver needs the child's registry id
/// (or its name). This parser never guesses that mapping.
public struct IORegDriver: Equatable, Sendable {
    public let nodeID: String?
    public let mediaName: String?
    public let bsdName: String?
    public let counters: IORegCounters
}

/// One driver's counter movement between two snapshots.
public struct IORegDriverDelta: Equatable, Sendable {
    public let nodeID: String?
    public let mediaName: String?
    public let bsdName: String?
    public let counters: IORegCounters
}

public struct IORegStatistics: Equatable, Sendable {
    public let drivers: [IORegDriver]

    /// Looks a driver up by the `BSD Name` in the recorded text. It returns nil
    /// for a plain `-k Statistics` capture, where the BSD name is not present.
    public func driver(forBSD bsd: String) -> IORegDriver? {
        drivers.first { $0.bsdName == bsd }
    }

    /// Counter movement between two snapshots, matched by IORegistry node id
    /// and falling back to the IOMedia name when ids are unavailable. A driver
    /// present in only one snapshot has no delta and is not invented.
    public static func delta(before: IORegStatistics, after: IORegStatistics) -> [IORegDriverDelta] {
        after.drivers.compactMap { afterDriver in
            guard let beforeDriver = before.drivers.first(where: { sameNode($0, afterDriver) }) else {
                return nil
            }
            return IORegDriverDelta(
                nodeID: afterDriver.nodeID,
                mediaName: afterDriver.mediaName,
                bsdName: afterDriver.bsdName,
                counters: IORegCounters.subtracting(beforeDriver.counters, from: afterDriver.counters)
            )
        }
    }

    private static func sameNode(_ lhs: IORegDriver, _ rhs: IORegDriver) -> Bool {
        if let left = lhs.nodeID, let right = rhs.nodeID {
            return left == right
        }
        guard let left = lhs.mediaName, let right = rhs.mediaName else { return false }
        return left == right
    }
}

public enum IORegParseError: Error, Equatable {
    case malformedStatistics
}

/// Parses the text of `ioreg -r -c IOBlockStorageDriver -k Statistics -w0`
/// (diskdoctor.md §4). Pure string to value; no process is run here.
public enum IORegStatisticsParser {
    public static func parse(_ text: String) throws -> IORegStatistics {
        var drivers: [IORegDriver] = []
        for block in driverBlocks(in: text) {
            guard let statistics = statisticsObject(in: block) else { continue }
            let counters = try parseCounters(statistics)
            drivers.append(
                IORegDriver(
                    nodeID: firstMatch(#"id (0x[0-9a-fA-F]+)"#, in: block).flatMap { $0[1] },
                    mediaName: firstMatch(#"(?m)^\s+\+-o (.+?)  <class IOMedia,"#, in: block).flatMap { $0[1] },
                    bsdName: firstMatch(#""BSD Name" = "([^"]+)""#, in: block).flatMap { $0[1] },
                    counters: counters
                )
            )
        }
        return IORegStatistics(drivers: drivers)
    }

    private static func driverBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if value.hasPrefix("+-o IOBlockStorageDriver") {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = [value]
            } else if !current.isEmpty {
                current.append(value)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    private static func statisticsObject(in block: String) -> String? {
        guard let line = block.split(separator: "\n").first(where: { $0.contains("\"Statistics\" = {") }),
              let open = line.firstIndex(of: "{"),
              let close = line.lastIndex(of: "}"),
              open < close
        else {
            return nil
        }
        return String(line[line.index(after: open)..<close])
    }

    private static func parseCounters(_ object: String) throws -> IORegCounters {
        var values: [String: Int64] = [:]
        for match in matches(#""([^"]+)"\s*=\s*(-?\d+)"#, in: object) {
            guard let key = match[1], let raw = match[2], let value = Int64(raw) else { continue }
            values[key] = value
        }
        guard !values.isEmpty else { throw IORegParseError.malformedStatistics }
        return IORegCounters(
            bytesRead: values["Bytes (Read)"],
            bytesWritten: values["Bytes (Write)"],
            operationsRead: values["Operations (Read)"],
            operationsWritten: values["Operations (Write)"],
            errorsRead: values["Errors (Read)"],
            errorsWritten: values["Errors (Write)"],
            retriesRead: values["Retries (Read)"],
            retriesWritten: values["Retries (Write)"],
            totalTimeRead: values["Total Time (Read)"],
            totalTimeWrite: values["Total Time (Write)"]
        )
    }
}

private func difference(_ before: Int64?, _ after: Int64?) -> Int64? {
    guard let before, let after else { return nil }
    return after - before
}

private func matches(_ pattern: String, in text: String) -> [[String?]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        (0..<match.numberOfRanges).map { index in
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
    }
}

private func firstMatch(_ pattern: String, in text: String) -> [String?]? {
    matches(pattern, in: text).first
}
