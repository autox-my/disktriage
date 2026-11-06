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
}
