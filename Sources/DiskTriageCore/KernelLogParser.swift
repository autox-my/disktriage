import Foundation

/// One kernel sense record, from `[External] I/O error! ... Sense Data 0x03,
/// 0x11, 0x00` (diskdoctor.md §4, Phase C findings). `repeats` is present only
/// on the coalesced form `Sense Data: ..., happened 42 times`.
public struct KernelLogSense: Equatable, Sendable {
    public let time: Date?
    public let senseKey: Int?
    public let asc: Int?
    public let ascq: Int?
    public let repeats: Int?
}

/// One read that failed on the medium, coalesced from its retry series.
///
/// `sectorCount` is the `count` field of the kernel line (0x20 and 0x100 in the
/// Phase C capture), `occurrences` is how many coalesced reads share this LBA
/// and size, and `maxRetry` is the highest retry number seen. The LBA is
/// decimal: the kernel prints hex, the SignalSet does not.
public struct KernelLogEvent: Equatable, Sendable {
    public let kind: String
    public let lba: Int?
    public let sectorCount: Int?
    public let direction: String?
    public let maxRetry: Int?
    public let occurrences: Int
    public let firstTime: Date?
    public let lastTime: Date?
    public let senseKey: Int?
    public let asc: Int?
    public let ascq: Int?
    public let bsd: String?
}

public struct KernelLogParseResult: Equatable, Sendable {
    public let events: [KernelLogEvent]
    public let senses: [KernelLogSense]
    /// The collector's own `log run noninteractively` line is returned by the
    /// predicate because its argv contains the predicate text. It is not a
    /// device event and is dropped; this count makes that drop observable.
    public let ignoredSelfQueryLines: Int
}

/// Parses the kernel lines of the unified log, in either `log show` style:
/// `--style ndjson` (`eventMessage` per JSON object) or the compact text style
/// (`timestamp Ty process[pid:tid] message`).
///
/// Lines from unrelated processes (Finder, storagekitd, `log` itself) are not
/// kernel disk errors and are ignored. Pure string to value; no process runs.
public enum KernelLogParser {
    public static func parse(_ text: String) -> KernelLogParseResult {
        var events: [KernelLogEvent] = []
        var senses: [KernelLogSense] = []
        var ignoredSelfQueryLines = 0
        var series: [RetrySeries] = []
        var current: RetrySeries?
        var pendingSense: KernelLogSense?
        var standalone: [KernelLogEvent] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let raw = rawLine(String(line)) else { continue }
            if raw.message.contains("log run noninteractively") {
                ignoredSelfQueryLines += 1
                continue
            }
            // A kernel disk error comes from the kernel. An unrelated process
            // that happens to print one of these words is not evidence.
            guard raw.process == "kernel" else { continue }

            if let sense = parseSense(raw) {
                senses.append(sense)
                pendingSense = sense
                continue
            }

            if let retry = parseRetry(raw) {
                if var open = current,
                   open.lba == retry.lba,
                   open.sectorCount == retry.sectorCount,
                   open.direction == retry.direction,
                   retry.retry == open.maxRetry + 1 {
                    open.maxRetry = retry.retry
                    open.lastTime = raw.time ?? open.lastTime
                    current = open
                } else {
                    if let open = current { series.append(open) }
                    current = RetrySeries(
                        lba: retry.lba,
                        sectorCount: retry.sectorCount,
                        direction: retry.direction,
                        maxRetry: retry.retry,
                        firstTime: raw.time,
                        lastTime: raw.time,
                        sense: pendingSense,
                        bsd: nil
                    )
                    pendingSense = nil
                }
                continue
            }

            if let bsd = parseDiskLine(raw) {
                if var open = current {
                    open.bsd = bsd
                    open.lastTime = raw.time ?? open.lastTime
                    series.append(open)
                    current = nil
                } else {
                    standalone.append(
                        KernelLogEvent(
                            kind: "medium_error",
                            lba: nil,
                            sectorCount: nil,
                            direction: nil,
                            maxRetry: nil,
                            occurrences: 1,
                            firstTime: raw.time,
                            lastTime: raw.time,
                            senseKey: pendingSense?.senseKey,
                            asc: pendingSense?.asc,
                            ascq: pendingSense?.ascq,
                            bsd: bsd
                        )
                    )
                }
            }
        }
        if let open = current { series.append(open) }

        events = coalesce(series) + standalone
        events.sort { ($0.firstTime ?? .distantPast) < ($1.firstTime ?? .distantPast) }
        return KernelLogParseResult(
            events: events,
            senses: senses,
            ignoredSelfQueryLines: ignoredSelfQueryLines
        )
    }

    private struct RetrySeries {
        let lba: Int
        let sectorCount: Int
        let direction: String?
        var maxRetry: Int
        let firstTime: Date?
        var lastTime: Date?
        let sense: KernelLogSense?
        var bsd: String?
    }

    private static func coalesce(_ series: [RetrySeries]) -> [KernelLogEvent] {
        var merged: [KernelLogEvent] = []
        for item in series {
            let index = merged.firstIndex {
                $0.lba == item.lba
                    && $0.sectorCount == item.sectorCount
                    && $0.direction == item.direction
            }
            if let index {
                let existing = merged[index]
                merged[index] = KernelLogEvent(
                    kind: existing.kind,
                    lba: existing.lba,
                    sectorCount: existing.sectorCount,
                    direction: existing.direction,
                    maxRetry: max(existing.maxRetry ?? 0, item.maxRetry),
                    occurrences: existing.occurrences + 1,
                    firstTime: existing.firstTime ?? item.firstTime,
                    lastTime: later(existing.lastTime, item.lastTime),
                    senseKey: existing.senseKey ?? item.sense?.senseKey,
                    asc: existing.asc ?? item.sense?.asc,
                    ascq: existing.ascq ?? item.sense?.ascq,
                    bsd: existing.bsd ?? item.bsd
                )
            } else {
                merged.append(
                    KernelLogEvent(
                        kind: "medium_error",
                        lba: item.lba,
                        sectorCount: item.sectorCount,
                        direction: item.direction,
                        maxRetry: item.maxRetry,
                        occurrences: 1,
                        firstTime: item.firstTime,
                        lastTime: item.lastTime,
                        senseKey: item.sense?.senseKey,
                        asc: item.sense?.asc,
                        ascq: item.sense?.ascq,
                        bsd: item.bsd
                    )
                )
            }
        }
        return merged
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }

    // MARK: - Line extraction

    private struct RawLine {
        let time: Date?
        let process: String
        let message: String
    }

    private static func rawLine(_ line: String) -> RawLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let message = dictionary["eventMessage"] as? String
            else {
                return nil
            }
            let path = dictionary["processImagePath"] as? String
                ?? dictionary["process"] as? String
                ?? ""
            return RawLine(
                time: (dictionary["timestamp"] as? String).flatMap(parseTimestamp),
                process: path.split(separator: "/").last.map(String.init) ?? path,
                message: message
            )
        }

        guard let match = firstMatch(
            #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,6})([+-]\d{4})?\s+\S+\s+([^\[]+)\[\d+:[0-9a-fA-F]+\]\s?(.*)$"#,
            in: line
        ) else {
            return nil
        }
        guard let stamp = match[1] else { return nil }
        let offset = match[2] ?? ""
        let process = match[3]?.trimmingCharacters(in: .whitespaces) ?? ""
        return RawLine(
            time: parseTimestamp(stamp + offset),
            process: process,
            message: match[4] ?? ""
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let hasOffset = value.range(of: #"[+-]\d{4}$"#, options: .regularExpression) != nil
        if hasOffset {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZ"
        } else {
            // Compact `log show` timestamps are local time with no offset.
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        }
        return formatter.date(from: value)
    }

    // MARK: - Message shapes

    private static func parseSense(_ raw: RawLine) -> KernelLogSense? {
        guard let match = firstMatch(
            #"Sense Data:?\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)(?:,\s*happened\s+(\d+)\s+times)?"#,
            in: raw.message
        ) else {
            return nil
        }
        return KernelLogSense(
            time: raw.time,
            senseKey: match[1].flatMap(hex),
            asc: match[2].flatMap(hex),
            ascq: match[3].flatMap(hex),
            repeats: match[4].flatMap(Int.init)
        )
    }

    private static func parseRetry(_ raw: RawLine) -> (lba: Int, sectorCount: Int, direction: String?, retry: Int)? {
        guard let match = firstMatch(
            #"I/O error \[0x[0-9a-fA-F]+\]\s+dir\s+(0x[0-9a-fA-F]+)\s+lba\s+(0x[0-9a-fA-F]+)\s+count\s+(0x[0-9a-fA-F]+),\s+retry\s+(\d+)"#,
            in: raw.message
        ) else {
            return nil
        }
        guard let direction = match[1].flatMap(hex),
              let lba = match[2].flatMap(hex),
              let sectorCount = match[3].flatMap(hex),
              let retry = match[4].flatMap(Int.init)
        else {
            return nil
        }
        return (lba: lba, sectorCount: sectorCount, direction: name(direction), retry: retry)
    }

    private static func parseDiskLine(_ raw: RawLine) -> String? {
        firstMatch(#"\b(disk\d+(?:s\d+)?): I/O error\."#, in: raw.message).flatMap { $0[1] }
    }

    private static func name(_ direction: Int) -> String? {
        switch direction {
        case 0x1: return "read"
        case 0x2: return "write"
        default: return nil
        }
    }
}

private func hex(_ value: String) -> Int? {
    let digits = value.hasPrefix("0x") || value.hasPrefix("0X")
        ? String(value.dropFirst(2))
        : value
    return Int(digits, radix: 16)
}

private func firstMatch(_ pattern: String, in text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
        return nil
    }
    return (0..<match.numberOfRanges).map { index in
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
