import Foundation
import Testing
import DiskTriageCore

/// The MiNaH fixture is the real case from diskdoctor.md §11: pending 131,
/// reallocated 14, medium error @ LBA 2048, a third-party NTFS driver, and no
/// history because it was the first sight of the drive.
/// Expected values are transcribed from the plan, never recomputed the way the
/// decoder computes them.
struct SignalSetTests {
    @Test("SignalSet decodes the MiNaH fixture (plan §3, §11)")
    func REQ0015_REQ0018_REQ0020_REQ0024_decodesTheMiNaHFixture() throws {
        let set = try JSONDecoder.disktriage().decode(SignalSet.self, from: try minahData())

        #expect(set.schemaVersion == 1, "schema_version")
        let expectedCollectedAt = try #require(
            ISO8601DateFormatter().date(from: "2026-11-06T00:14:02Z"),
            "expected collected_at in the test"
        )
        #expect(set.collectedAt == expectedCollectedAt, "collected_at")

        let device = try #require(set.device, "device section")
        #expect(device.status == .ok, "device.status")
        #expect(device.bsd == "disk4", "device.bsd")
        #expect(device.sizeBytes == 320_072_933_376, "device.size_bytes")
        #expect(device.model == "WDC WD3200BJKT-75F4T0", "device.model")
        #expect(device.serial == "WD-WX0123456789", "device.serial")
        #expect(device.media == "hdd", "device.media")
        #expect(device.bus == "usb", "device.bus")
        #expect(device.satPassthrough == "partial", "device.sat_passthrough")
        #expect(device.removable == true, "device.removable")

        let smart = try #require(set.smart, "smart section")
        #expect(smart.status == .ok, "smart.status")
        #expect(smart.overall == "PASSED", "smart.overall")
        #expect(try #require(smart.pending, "smart.pending") == 131, "smart.pending")
        #expect(try #require(smart.reallocated, "smart.reallocated") == 14, "smart.reallocated")
        #expect(try #require(smart.uncorrectable, "smart.uncorrectable") == 0, "smart.uncorrectable")
        #expect(try #require(smart.powerOnHours, "smart.power_on_hours") == 4_531, "smart.power_on_hours")
        #expect(try #require(smart.rawReadErrors, "smart.raw_read_errors") == 21_545, "smart.raw_read_errors")

        let firstError = try #require(smart.errorLog?.first, "smart.error_log[0]")
        #expect(firstError.lba == 2048, "smart.error_log[0].lba")
        #expect(firstError.count == 6, "smart.error_log[0].count")
        #expect(smart.selfTest?.last == "completed-no-error", "smart.self_test.last")

        // First sight of the drive: there is no snapshot to invent a trend from.
        #expect(smart.history == nil, "smart.history")

        let io = try #require(set.io, "io section")
        #expect(io.retries == 1_204, "io.retries")
        #expect(io.timeouts == 3, "io.timeouts")

        let log = try #require(set.log, "log section")
        #expect(log.windowHours == 72, "log.window_hours")
        let event = try #require(log.events?.first, "log.events[0]")
        #expect(event.kind == "medium_error", "log.events[0].kind")
        #expect(event.lba == 2048, "log.events[0].lba")

        let driver = try #require(set.drivers?.items?.first, "drivers.items[0]")
        #expect(driver.thirdParty == true, "drivers.items[0].third_party")
        #expect(driver.claims == ["ntfs"], "drivers.items[0].claims")

        let permissions = try #require(set.permissions, "permissions section")
        #expect(permissions.root == true, "permissions.root")
        #expect(permissions.rawRead == .denied, "permissions.raw_read")
        #expect(permissions.removableVolumes == .granted, "permissions.removable_volumes")

        let fs = try #require(set.fs, "fs section")
        #expect(fs.type == "ntfs", "fs.type")
        #expect(fs.mounted == false, "fs.mounted")
        #expect(fs.readable == nil, "fs.readable")

        let symptoms = try #require(set.symptoms, "symptoms section")
        #expect(symptoms.source == "user", "symptoms.source")
        #expect(symptoms.clicking == false, "symptoms.clicking")
        #expect(symptoms.worksOnOtherPort == nil, "symptoms.works_on_other_port")

        let note = try #require(set.collectorNotes?.first, "collector_notes[0]")
        #expect(note.collector == "diskutil", "collector_notes[0].collector")
        #expect(note.outcome == .timeout, "collector_notes[0].outcome")
        #expect(note.afterSeconds == 10, "collector_notes[0].after_s")
    }

    @Test("absent counters stay nil, never zero")
    func REQ0021_REQ0022_absentCountersStayNil() throws {
        let json = """
        {
          "schema_version": 1,
          "collected_at": "2026-11-06T00:14:02Z",
          "smart": { "status": "denied" }
        }
        """
        let set = try JSONDecoder.disktriage().decode(SignalSet.self, from: Data(json.utf8))
        let smart = try #require(set.smart, "smart section")

        #expect(smart.status == .denied, "smart.status")
        #expect(smart.pending == nil, "smart.pending")
        #expect(smart.reallocated == nil, "smart.reallocated")
        #expect(smart.uncorrectable == nil, "smart.uncorrectable")
        #expect(smart.rawReadErrors == nil, "smart.raw_read_errors")
        #expect(set.device == nil, "device section")
    }

    @Test("an unrecognised signal status fails closed")
    func REQ0020_anUnrecognisedSignalStatusFailsClosed() {
        let json = """
        { "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "smart": { "status": "probably-fine" } }
        """
        #expect(throws: (any Error).self, "unknown smart.status") {
            _ = try JSONDecoder.disktriage().decode(SignalSet.self, from: Data(json.utf8))
        }
    }
}

/// Tests/Fixtures/minah.json, located from this file so the fixture lives
/// outside the test target without being copied into a bundle.
private func minahData() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/minah.json")
    return try Data(contentsOf: url)
}
