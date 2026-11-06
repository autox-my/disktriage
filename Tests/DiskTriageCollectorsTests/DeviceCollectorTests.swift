import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// The internal disk's real `diskutil info -plist` recording, redacted. The
/// expectations below are read off that fixture, not recomputed by the parser.
struct DeviceCollectorTests {
    // REQ-0020: every collected section carries a status.
    // REQ-0023: a non-ok status is not a measurement.
    @Test("the internal Apple NVMe recording parses to the unsupported-media path")
    func internalNVMeParsesToUnsupportedMedia() throws {
        let collection = DeviceCollector(executor: StubExecutor(info: .ok(fixtureText())))
            .collect(bsd: "disk0")

        #expect(collection.status == .ok, "status")
        let identity = try #require(collection.identity, "identity")
        #expect(identity.bsd == "disk0", "bsd")
        #expect(identity.sizeBytes == 251_000_193_024, "size_bytes")
        #expect(identity.model == "APPLE SSD AP0256Q", "model")
        #expect(identity.serial == nil, "the plist carries no serial")
        #expect(identity.media == "ssd", "SolidState=true maps to ssd")
        #expect(identity.bus == "nvme", "BusProtocol=Apple Fabric maps to nvme")
        #expect(identity.removable == false, "removable")
        #expect(identity.blockSize == 4096, "block size")
        #expect(identity.internalDisk == true, "internal")

        var builder = SignalSetBuilder(collectedAt: try collectedAt())
        builder.setDevice(collection)
        let set = try builder.build()
        let device = try #require(set.device, "device section")
        #expect(device.status == .ok, "device.status")
        #expect(device.media == "ssd", "device.media")
        #expect(device.bus == "nvme", "device.bus")

        let verdict = classify(set)
        #expect(verdict.code == .insufficientEvidence, "unsupported media is not a health verdict")
        let note = try #require(verdict.unsupportedNote, "unsupported note")
        #expect(note.contains("ssd"), "the classifier names the media: \(note)")
    }

    @Test("enumeration keeps whole disks and drops slices")
    func enumerationKeepsWholeDisks() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>AllDisks</key>
          <array>
            <string>disk0</string><string>disk0s1</string>
            <string>disk4</string>
          </array>
        </dict></plist>
        """
        let collector = DeviceCollector(executor: StubExecutor(
            info: .ok(fixtureText()),
            list: .ok(plist)
        ))
        #expect(collector.enumerateWholeDisks() == ["disk0", "disk4"], "whole disks only")
    }

    @Test("a timeout is a timeout status with nil counters, never zeros")
    func timeoutIsATimeoutStatus() throws {
        let collection = DeviceCollector(executor: StubExecutor(info: .timeout()))
            .collect(bsd: "disk0")

        #expect(collection.status == .timeout, "status")
        #expect(collection.identity == nil, "no identity")

        var builder = SignalSetBuilder(collectedAt: try collectedAt())
        builder.setDevice(collection)
        let set = try builder.build()
        let device = try #require(set.device, "device section")
        #expect(device.status == .timeout, "device.status")
        #expect(device.sizeBytes == nil, "size is nil, not zero")
        #expect(device.model == nil, "model is nil, not empty")
        #expect(builder.unsupportedReasons["device"]?.isEmpty == false, "the reason is recorded")
    }

    @Test("denied is reported as denied, not as a device with no fields")
    func deniedIsDenied() {
        let collection = DeviceCollector(executor: StubExecutor(info: .denied()))
            .collect(bsd: "disk0")
        #expect(collection.status == .denied, "status")
        #expect(collection.identity == nil, "no identity")
    }

    @Test("an unparsable plist is an error status")
    func malformedPlistIsAnError() {
        let collection = DeviceCollector(executor: StubExecutor(info: .ok("not a plist")))
            .collect(bsd: "disk0")
        #expect(collection.status == .error, "status")
        #expect(collection.identity == nil, "no identity")
    }
}

struct StubExecutor: CommandExecuting {
    let info: CollectorResult
    let list: CollectorResult

    init(info: CollectorResult, list: CollectorResult = .ok("")) {
        self.info = info
        self.list = list
    }

    func run(_ command: TriageCommand) -> CollectorResult {
        switch command {
        case .diskutilList:
            return list
        case .diskutilInfo:
            return info
        default:
            return info
        }
    }
}

private func collectedAt() throws -> Date {
    try #require(ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z"))
}

/// Tests/Fixtures/diskutil-info-internal.plist, located from this file.
func fixtureText() -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCollectorsTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/diskutil-info-internal.plist")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
