import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// The builder must never leave a section absent or turn "not collected" into a
/// zero (diskdoctor.md §2.3, §3).
struct SignalSetBuilderTests {
    private let collectedAt = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!

    // REQ-0020: every signal section carries a status.
    @Test("every section carries a status and uncollected sections are unsupported")
    func REQ0020_everySectionCarriesAStatus() throws {
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        let set = try builder.build()

        let statuses: [(String, SignalStatus?)] = [
            ("device", set.device?.status),
            ("smart", set.smart?.status),
            ("io", set.io?.status),
            ("log", set.log?.status),
            ("drivers", set.drivers?.status),
            ("fs", set.fs?.status),
        ]
        for (name, status) in statuses {
            #expect(status != nil, "\(name) section is present")
            #expect(SignalStatus.allCases.contains(status!), "\(name) has a known status")
        }
        #expect(set.device?.status == .unsupported, "device was not collected")
        #expect(set.smart?.status == .unsupported, "smart was not collected")
        #expect(set.io?.status == .unsupported, "io was not collected")
        #expect(set.log?.status == .unsupported, "log was not collected")
        #expect(set.drivers?.status == .unsupported, "drivers was not collected")
        #expect(set.fs?.status == .unsupported, "fs was not collected")
    }

    // REQ-0023: unsupported and timeout are distinct from numeric values.
    @Test("an unsupported section has no counters, never zero")
    func REQ0023_unsupportedHasNoCounters() throws {
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        let set = try builder.build()

        #expect(set.smart?.pending == nil, "smart.pending")
        #expect(set.smart?.reallocated == nil, "smart.reallocated")
        #expect(set.smart?.uncorrectable == nil, "smart.uncorrectable")
        #expect(set.smart?.history == nil, "no invented history")
        #expect(set.io?.retries == nil, "io.retries")
        #expect(set.io?.timeouts == nil, "io.timeouts")
        #expect(set.log?.events == nil, "log.events")
        #expect(set.fs?.readable == nil, "fs.readable")
    }

    @Test("a not-collected section carries its reason and a collector note")
    func uncollectedSectionsCarryAReason() throws {
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        builder.markUnsupported(section: "log", reason: "no unified-log collector yet")
        let set = try builder.build()

        #expect(builder.unsupportedReasons["smart"]?.isEmpty == false, "smart reason")
        #expect(builder.unsupportedReasons["log"] == "no unified-log collector yet", "override reason")
        #expect(builder.unsupportedReasons["io"]?.isEmpty == false, "io reason")

        let notes = try #require(set.collectorNotes, "collector_notes")
        #expect(notes.contains { $0.collector == "smartctl" && $0.outcome == .unsupported }, "smart note")
        #expect(notes.contains { $0.collector == "unified-log" && $0.outcome == .unsupported }, "log note")
    }

    @Test("a collected device replaces the unsupported placeholder")
    func collectedDeviceReplacesThePlaceholder() throws {
        let collection = DeviceCollector(executor: StubExecutor(info: .ok(fixtureText())))
            .collect(bsd: "disk0")
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        builder.setDevice(collection)
        let set = try builder.build()

        #expect(set.device?.status == .ok, "device.status")
        #expect(set.device?.bsd == "disk0", "device.bsd")
        #expect(set.device?.sizeBytes == 251_000_193_024, "device.size_bytes")
        #expect(builder.unsupportedReasons["device"] == nil, "no device reason once collected")
        #expect(set.smart?.status == .unsupported, "the other sections stay unsupported")
    }

    // REQ-0029: I/O statistics are displayed without being counted until P0
    // validates the real counters; the flag stays off by default.
    @Test("the real MiNaH ioreg delta fills io but leaves the P0 flag off")
    func REQ0029_theIORegDeltaIsDisplayedAndNotValidated() throws {
        let delta = try minahDelta()
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        builder.setIO(delta)
        let set = try builder.build()

        let io = try #require(set.io, "io section")
        #expect(io.status == .ok, "ioreg answered")
        #expect(io.retries == 0, "Retries (Read) stayed 0")
        #expect(io.errors == 1, "Errors (Read) 0 -> 1")
        #expect(io.timeouts == nil, "ioreg has no timeouts counter; never invent one")
        #expect(io.p0Validated == nil, "P0 has not validated the counters")
        #expect(builder.unsupportedReasons["io"] == nil, "io is no longer unsupported")
    }

    @Test("a healthy ioreg delta is a real zero, not an absent counter")
    func theHealthyIORegDeltaIsAZeroMeasurement() throws {
        let before = try IORegStatisticsParser.parse(collectorFixtureText("ioreg-phase-b-before.txt"))
        let after = try IORegStatisticsParser.parse(collectorFixtureText("ioreg-phase-b-after.txt"))
        let delta = try #require(
            IORegStatistics.delta(before: before, after: after)
                .first { $0.mediaName == "Seagate Expansion Media" }
        )

        var builder = SignalSetBuilder(collectedAt: collectedAt)
        builder.setIO(delta)
        let set = try builder.build()

        #expect(set.io?.status == .ok, "status")
        #expect(set.io?.retries == 0, "a measured zero")
        #expect(set.io?.errors == 0, "a measured zero")
        #expect(set.io?.timeouts == nil, "not measured")
    }

    @Test("the real kernel log becomes log events with a decimal LBA and a window")
    func theKernelLogBecomesLogEvents() throws {
        let parsed = KernelLogParser.parse(try collectorFixtureText("kernel-log-medium-errors.ndjson"))
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        builder.setLog(parsed.events, windowHours: 1)
        let set = try builder.build()

        let log = try #require(set.log, "log section")
        #expect(log.status == .ok, "log show answered")
        #expect(log.windowHours == 1, "the --last 10m query window")
        let events = try #require(log.events, "events")
        #expect(events.count == 2, "one event per read size")
        let dd = try #require(events.first { $0.count == 1 }, "the 0x100 dd read")
        #expect(dd.kind == "medium_error", "kind")
        #expect(dd.lba == 2048, "decimal LBA, not 0x800")
        #expect(dd.firstTime == ISO8601DateFormatter().date(from: "2026-11-06T16:34:39Z"),
                "first_time is the burst's first retry")
        let probe = try #require(events.first { $0.count == 2 }, "the 0x20 probe reads")
        #expect(probe.lba == 2048, "decimal LBA")
        #expect(builder.unsupportedReasons["log"] == nil, "log is no longer unsupported")
    }

    @Test("a healthy log is an ok section with zero events, not an absent one")
    func theHealthyLogIsAnEmptyOKSection() throws {
        let parsed = KernelLogParser.parse(try collectorFixtureText("kernel-log-healthy-compact.txt"))
        var builder = SignalSetBuilder(collectedAt: collectedAt)
        builder.setLog(parsed.events, windowHours: 1)
        let set = try builder.build()

        #expect(set.log?.status == .ok, "log was measured")
        #expect(set.log?.events?.isEmpty == true, "zero medium errors")
        #expect(set.log?.windowHours == 1, "window")
    }
}

private func collectorFixtureText(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCollectorsTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func minahDelta() throws -> IORegDriverDelta {
    let before = try IORegStatisticsParser.parse(collectorFixtureText("ioreg-phase-c-before.txt"))
    let after = try IORegStatisticsParser.parse(collectorFixtureText("ioreg-phase-c-after.txt"))
    return try #require(
        IORegStatistics.delta(before: before, after: after)
            .first { $0.mediaName == "Generic External Media" }
    )
}
