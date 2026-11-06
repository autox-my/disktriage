import Foundation
import DiskDoctorCore

/// The MiNaH fixture is the real case from diskdoctor.md §11: pending 131,
/// reallocated 14, medium error @ LBA 2048, a third-party NTFS driver, and no
/// history because it was the first sight of the drive.
/// Expected values are transcribed from the plan, never recomputed the way the
/// decoder computes them.
@MainActor
func signalSetTests() {
    test("SignalSet decodes the MiNaH fixture (plan §3, §11)") {
        let set = try JSONDecoder.diskDoctor().decode(SignalSet.self, from: try minahData())

        try expectEqual(set.schemaVersion, 1, "schema_version")
        let expectedCollectedAt = try require(
            ISO8601DateFormatter().date(from: "2026-11-06T00:14:02Z"),
            "expected collected_at in the test"
        )
        try expectEqual(set.collectedAt, expectedCollectedAt, "collected_at")

        let device = try require(set.device, "device section")
        try expectEqual(device.status, .ok, "device.status")
        try expectEqual(device.bsd, "disk4", "device.bsd")
        try expectEqual(device.sizeBytes, 320_072_933_376, "device.size_bytes")
        try expectEqual(device.model, "WDC WD3200BJKT-75F4T0", "device.model")
        try expectEqual(device.serial, "WD-WX0123456789", "device.serial")
        try expectEqual(device.media, "hdd", "device.media")
        try expectEqual(device.bus, "usb", "device.bus")
        try expectEqual(device.satPassthrough, "partial", "device.sat_passthrough")
        try expectEqual(device.removable, true, "device.removable")

        let smart = try require(set.smart, "smart section")
        try expectEqual(smart.status, .ok, "smart.status")
        try expectEqual(smart.overall, "PASSED", "smart.overall")
        try expectEqual(try require(smart.pending, "smart.pending"), 131, "smart.pending")
        try expectEqual(try require(smart.reallocated, "smart.reallocated"), 14, "smart.reallocated")
        try expectEqual(try require(smart.uncorrectable, "smart.uncorrectable"), 0, "smart.uncorrectable")
        try expectEqual(try require(smart.powerOnHours, "smart.power_on_hours"), 4_531, "smart.power_on_hours")
        try expectEqual(try require(smart.rawReadErrors, "smart.raw_read_errors"), 21_545, "smart.raw_read_errors")

        let firstError = try require(smart.errorLog?.first, "smart.error_log[0]")
        try expectEqual(firstError.lba, 2048, "smart.error_log[0].lba")
        try expectEqual(firstError.count, 6, "smart.error_log[0].count")
        try expectEqual(smart.selfTest?.last, "completed-no-error", "smart.self_test.last")

        // First sight of the drive: there is no snapshot to invent a trend from.
        try expectNil(smart.history, "smart.history")

        let io = try require(set.io, "io section")
        try expectEqual(io.retries, 1_204, "io.retries")
        try expectEqual(io.timeouts, 3, "io.timeouts")

        let log = try require(set.log, "log section")
        try expectEqual(log.windowHours, 72, "log.window_hours")
        let event = try require(log.events?.first, "log.events[0]")
        try expectEqual(event.kind, "medium_error", "log.events[0].kind")
        try expectEqual(event.lba, 2048, "log.events[0].lba")

        let driver = try require(set.drivers?.items?.first, "drivers.items[0]")
        try expectEqual(driver.thirdParty, true, "drivers.items[0].third_party")
        try expectEqual(driver.claims, ["ntfs"], "drivers.items[0].claims")

        let permissions = try require(set.permissions, "permissions section")
        try expectEqual(permissions.root, true, "permissions.root")
        try expectEqual(permissions.rawRead, .denied, "permissions.raw_read")
        try expectEqual(permissions.removableVolumes, .granted, "permissions.removable_volumes")

        let fs = try require(set.fs, "fs section")
        try expectEqual(fs.type, "ntfs", "fs.type")
        try expectEqual(fs.mounted, false, "fs.mounted")
        try expectNil(fs.readable, "fs.readable")

        let symptoms = try require(set.symptoms, "symptoms section")
        try expectEqual(symptoms.source, "user", "symptoms.source")
        try expectEqual(symptoms.clicking, false, "symptoms.clicking")
        try expectNil(symptoms.worksOnOtherPort, "symptoms.works_on_other_port")

        let note = try require(set.collectorNotes?.first, "collector_notes[0]")
        try expectEqual(note.collector, "diskutil", "collector_notes[0].collector")
        try expectEqual(note.outcome, .timeout, "collector_notes[0].outcome")
        try expectEqual(note.afterSeconds, 10, "collector_notes[0].after_s")
    }

    test("absent counters stay nil, never zero") {
        let json = """
        {
          "schema_version": 1,
          "collected_at": "2026-11-06T00:14:02Z",
          "smart": { "status": "denied" }
        }
        """
        let set = try JSONDecoder.diskDoctor().decode(SignalSet.self, from: Data(json.utf8))
        let smart = try require(set.smart, "smart section")

        try expectEqual(smart.status, .denied, "smart.status")
        try expectNil(smart.pending, "smart.pending")
        try expectNil(smart.reallocated, "smart.reallocated")
        try expectNil(smart.uncorrectable, "smart.uncorrectable")
        try expectNil(smart.rawReadErrors, "smart.raw_read_errors")
        try expectNil(set.device, "device section")
    }

    test("an unrecognised signal status fails closed") {
        let json = """
        { "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "smart": { "status": "probably-fine" } }
        """
        try expectThrows(
            { _ = try JSONDecoder.diskDoctor().decode(SignalSet.self, from: Data(json.utf8)) },
            "unknown smart.status"
        )
    }
}

/// Tests/Fixtures/minah.json, located from this file so the fixture lives
/// outside the test target without being copied into a bundle.
private func minahData() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskDoctorCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/minah.json")
    return try Data(contentsOf: url)
}
