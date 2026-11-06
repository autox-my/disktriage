import Foundation
import Testing
import DiskTriageCore

/// Pin the kernel-log parser to the real Phase C medium-error burst and to the
/// healthy Phase B control. Values come from docs/p0-runbook.md's Phase C
/// findings: LBA 0x800 = 2048, retries 1..20 about 2.2 s apart, 0x20 for the
/// probe and 0x100 for the dd read, then `diskN: I/O error.`.
struct KernelLogParserTests {

    @Test("the real Phase C ndjson gives two coalesced reads at LBA 2048")
    func phaseCNDJSONCoalescesTheRealBurst() throws {
        let result = KernelLogParser.parse(try fixtureText("kernel-log-medium-errors.ndjson"))

        #expect(result.events.count == 2, "one event per read size, not one per retry")

        let dd = try #require(result.events.first { $0.sectorCount == 256 },
                              "the count 0x100 dd read")
        #expect(dd.kind == "medium_error", "kind")
        #expect(dd.lba == 2048, "LBA 0x800 is decimal 2048")
        #expect(dd.maxRetry == 20, "retry 1..20")
        #expect(dd.occurrences == 1, "one dd read")
        #expect(dd.direction == "read", "dir 0x1")
        #expect(dd.senseKey == 3, "sense key 3 = MEDIUM ERROR")
        #expect(dd.asc == 0x11, "ASC 0x11 = unrecovered read error")
        #expect(dd.ascq == 0x00, "ASCQ 0x00")
        #expect(dd.bsd == "disk8", "the whole-disk I/O error closes the series")
        #expect(dd.firstTime == capturedDate("2026-11-06T16:34:39.222Z"),
                "00:34:39.222440+0800")
        #expect(dd.lastTime == capturedDate("2026-11-06T16:35:25.342Z"),
                "00:35:25.342861+0800")

        let probe = try #require(result.events.first { $0.sectorCount == 32 },
                                 "the count 0x20 probe reads")
        #expect(probe.lba == 2048, "same medium error")
        #expect(probe.maxRetry == 20, "each probe read retried 20 times")
        #expect(probe.occurrences == 2, "two probe bursts coalesce into one event")
        #expect(probe.bsd == "disk8s1", "the slice I/O error closes each probe series")
        #expect(probe.firstTime == capturedDate("2026-11-06T16:31:21.190Z"),
                "the first probe burst")
        #expect(probe.lastTime == capturedDate("2026-11-06T16:32:57.302Z"),
                "the second probe burst")
    }

    @Test("the coalesced sense line keeps its 42-repeat count")
    func theRepeatCountVariantIsParsed() throws {
        let result = KernelLogParser.parse(try fixtureText("kernel-log-medium-errors.ndjson"))

        let repeated = try #require(result.senses.first { $0.repeats == 42 },
                                    "Sense Data: ... happened 42 times")
        #expect(repeated.senseKey == 3, "MEDIUM ERROR")
        #expect(repeated.asc == 0x11, "unrecovered read error")
        #expect(repeated.ascq == 0x00, "ASCQ")
    }

    @Test("the healthy Phase B log and the query's own line yield no events")
    func theHealthyControlHasNoMediumErrorEvents() throws {
        let result = KernelLogParser.parse(try fixtureText("kernel-log-healthy-compact.txt"))

        #expect(result.events.isEmpty, "a healthy disk has no medium errors")
        #expect(result.senses.isEmpty, "and no sense records")
        #expect(result.ignoredSelfQueryLines == 1, "the log run noninteractively line is dropped")
    }

    @Test("the compact style parses the same kernel line shapes")
    func compactStyleParsesStructuredKernelLines() throws {
        let result = KernelLogParser.parse(try fixtureText("kernel-log-medium-errors-compact.txt"))

        #expect(result.events.count == 1, "one read, two retries")
        let event = try #require(result.events.first, "the compact event")
        #expect(event.lba == 2048, "LBA 0x800 is decimal 2048")
        #expect(event.sectorCount == 32, "count 0x20")
        #expect(event.maxRetry == 2, "retry 1..2 in the slice")
        #expect(event.bsd == "disk8s1", "the slice line")
        #expect(event.firstTime != nil, "the compact timestamp is parsed")
    }
}

private func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixtureData(name), as: UTF8.self)
}

/// The captured timestamps are +0800; the expectations above are their UTC
/// equivalents, transcribed rather than converted by the parser's own code.
private func capturedDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.date(from: value)
}
