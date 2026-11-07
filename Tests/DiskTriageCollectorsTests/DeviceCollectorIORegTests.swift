import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// The identity path that must keep working while diskarbitrationd is
/// stopped. The P0 phase C runbook measured that `diskutil` hangs system-wide
/// in that state, so the collector must never wait on it.
struct DeviceCollectorIORegTests {

    private func internalTree() throws -> String {
        try collectorFixture("ioreg-device-internal.txt")
    }

    private func usbNoSerialTree() throws -> String {
        try collectorFixture("ioreg-device-usb-hdd-no-serial.txt")
    }

    private func usbWithSerialTree() throws -> String {
        try collectorFixture("ioreg-device-usb-with-serial.txt")
    }

    // REQ-0161: a stopped diskarbitrationd means diskutil is never run.
    @Test("REQ-0161 stopped DiskArbitration uses ioreg and never invokes diskutil")
    func REQ0161_stoppedDiskArbitrationSkipsDiskutil() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
            .ioregDeviceTree: .ok(try internalTree()),
            .diskutilInfo(disk: "disk0"): .ok("must not be used"),
        ])

        let collection = DeviceCollector(executor: executor).collect(bsd: "disk0")

        #expect(collection.status == .ok, "the ioreg path is a measurement")
        #expect(collection.source == .ioreg, "the source is recorded")
        #expect(collection.reason == "diskarbitrationd is stopped; diskutil skipped")
        #expect(collection.identity?.serial == "REDACTED0000ABCD", "identity from ioreg")
        #expect(!executor.commands.contains { command in
            if case .diskutilInfo = command { return true }
            return false
        }, "diskutil was not invoked while it would hang")
    }

    // REQ-0161 / REQ-0162: the running-daemon path stays exactly as it was.
    @Test("REQ0161 a running DiskArbitration still reads identity from diskutil")
    func REQ0161_runningDiskArbitrationKeepsDiskutil() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("Ss\n"),
            .diskutilInfo(disk: "disk0"): .ok(try collectorFixture("diskutil-info-internal.plist")),
            .ioregDeviceTree: .ok(try internalTree()),
        ])

        let collection = DeviceCollector(executor: executor).collect(bsd: "disk0")

        #expect(collection.status == .ok)
        #expect(collection.source == .diskutil, "diskutil first when it cannot hang")
        #expect(collection.identity?.model == "APPLE SSD AP0256Q")
        #expect(!executor.commands.contains(.ioregDeviceTree), "no needless ioreg fallback")
    }

    // REQ-0164: a timeout is evidence, not a crash, and it survives the fallback.
    @Test("REQ-0164 a diskutil timeout falls back to ioreg and keeps the timeout evidence")
    func REQ0164_diskutilTimeoutFallsBackAndKeepsEvidence() throws {
        let executor = RecordingExecutor([
            // pgrep returning nothing means "not established", not "stopped".
            .pgrepDiskArbitrationDaemon: .ok(""),
            .diskutilInfo(disk: "disk8"): CollectorResult(outcome: .timeout, durationMs: 30_000),
            .ioregDeviceTree: .ok(try usbNoSerialTree()),
        ])

        let collection = DeviceCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .ok, "the fallback produced a real identity")
        #expect(collection.source == .ioreg)
        #expect(collection.diskutilTimeoutMs == 30_000, "the 30 s timeout is retained")
        #expect(collection.reason?.contains("timed out after 30000 ms") == true,
                "the reason carries the timeout evidence: \(collection.reason ?? "nil")")
        #expect(collection.identity?.sizeBytes == 5_000_981_077_504)
        #expect(collection.identity?.serial == nil, "an unexposed serial stays nil")
    }

    // REQ-0162: the USB host device's serial is used when the bridge hides it
    // on the block device, and the association is by the same BSD name.
    @Test("REQ-0162 the USB host device supplies the serial the bridge hides")
    func REQ0162_usbHostSerialIsUsed() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
            .ioregDeviceTree: .ok(try usbNoSerialTree()),
            .ioregUSBDeviceTree: .ok(try usbWithSerialTree()),
        ])

        let collection = DeviceCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .ok)
        #expect(collection.identity?.serial == "DEMO-USB-0000ABCD")
        #expect(collection.identity?.model == "Expansion", "the block device's product name wins")
        #expect(collection.identity?.bus == "usb")
    }

    @Test("DISKTRIAGE_FORCE_IOREG=1 forces the ioreg path (test-only seam)")
    func forceIORegEnvironmentSkipsDiskutil() throws {
        let executor = RecordingExecutor([
            .ioregDeviceTree: .ok(try usbNoSerialTree()),
            .diskutilInfo(disk: "disk8"): .ok("must not be used"),
        ])

        let collection = DeviceCollector(
            executor: executor,
            environment: ["DISKTRIAGE_FORCE_IOREG": "1"]
        ).collect(bsd: "disk8")

        #expect(collection.status == .ok)
        #expect(collection.source == .ioreg)
        #expect(collection.reason?.contains("DISKTRIAGE_FORCE_IOREG=1") == true)
        #expect(!executor.commands.contains { command in
            if case .diskutilInfo = command { return true }
            return false
        })
    }

    @Test("a fallback whose ioreg also fails keeps both failures and no identity")
    func failedFallbackKeepsTheTimeoutEvidence() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok(""),
            .diskutilInfo(disk: "disk8"): CollectorResult(outcome: .timeout, durationMs: 30_000),
            .ioregDeviceTree: CollectorResult(outcome: .error, durationMs: 12),
        ])

        let collection = DeviceCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .error, "the ioreg error is the final outcome")
        #expect(collection.identity == nil, "no identity is invented")
        #expect(collection.diskutilTimeoutMs == 30_000, "the timeout evidence is not lost")
        #expect(collection.reason?.contains("timed out") == true)
    }
}
