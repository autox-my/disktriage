import Foundation
import Testing
import DiskTriageCore
@testable import DiskTriageCollectors

/// Enumeration is the other `diskutil` call on the live `triage`, `list` and
/// FDA-probe paths. While DiskArbitration is stopped it must come from ioreg,
/// and a timeout must fall back once instead of hanging.
struct DeviceCollectorEnumerateIORegTests {

    private func internalTree() throws -> String {
        try collectorFixture("ioreg-device-internal.txt")
    }

    private func usbTree() throws -> String {
        try collectorFixture("ioreg-device-usb-with-serial.txt")
    }

    // REQ-0165: stopped DiskArbitration enumerates through ioreg, never
    // diskutil list.
    @Test("REQ0165 stopped DiskArbitration enumerates whole disks from ioreg")
    func REQ0165_stoppedDAEnumeratesFromIOReg() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
            .ioregDeviceTree: .ok(try internalTree()),
            .diskutilList: .ok("must not be used"),
        ])

        let enumeration = DeviceCollector(executor: executor).enumerate()

        #expect(enumeration.status == .ok)
        #expect(enumeration.disks == ["disk0"], "the internal whole disk")
        #expect(enumeration.reason == "diskarbitrationd is stopped; diskutil skipped")
        #expect(!executor.commands.contains(.diskutilList), "diskutil list was never invoked")
    }

    // REQ-0165: a timeout is evidence, and the one-shot ioreg fallback keeps
    // triage moving instead of waiting on a hung diskutil.
    @Test("REQ0165 a diskutil list timeout falls back to ioreg once")
    func REQ0165_diskutilListTimeoutFallsBack() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok(""),
            .diskutilList: CollectorResult(outcome: .timeout, durationMs: 10_000),
            .ioregDeviceTree: .ok(try usbTree()),
        ])

        let enumeration = DeviceCollector(executor: executor).enumerate()

        #expect(enumeration.status == .ok)
        #expect(enumeration.disks == ["disk8"])
        #expect(enumeration.reason?.contains("timed out after 10000 ms") == true,
                "the timeout is kept as evidence: \(enumeration.reason ?? "nil")")
        #expect(executor.commands.contains(.ioregDeviceTree))
    }

    // The running-daemon path is unchanged.
    @Test("REQ0165 a running DiskArbitration still enumerates with diskutil list")
    func REQ0165_runningDAKeepsDiskutilList() {
        let list = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>AllDisks</key>
          <array><string>disk0</string><string>disk0s1</string><string>disk8</string></array>
        </dict></plist>
        """
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("Ss\n"),
            .diskutilList: .ok(list),
        ])

        let enumeration = DeviceCollector(executor: executor).enumerate()

        #expect(enumeration.disks == ["disk0", "disk8"], "slices are filtered out")
        #expect(!executor.commands.contains(.ioregDeviceTree), "no needless fallback")
    }

    // REQ-0165: the FDA probe's internal-disk locator uses the same
    // enumeration, so a stopped daemon does not make `image` fail its
    // precondition.
    @Test("REQ0165 the internal probe node is found while DiskArbitration is stopped")
    func REQ0165_internalProbeUsesIOReg() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
            .ioregDeviceTree: .ok(try internalTree()),
        ])

        let node = InternalDiskLocator(executor: executor).internalRawNode()

        #expect(node == "/dev/rdisk0", "the internal raw node")
        #expect(!executor.commands.contains(.diskutilList))
        #expect(!executor.commands.contains { command in
            if case .diskutilInfo = command { return true }
            return false
        })
    }

    // A synthesized APFS container is whole but virtual; the probe must not
    // choose it even when it appears first in the registry tree.
    @Test("REQ0165 a synthesized APFS media reports Virtual from ioreg")
    func REQ0165_apfsMediaIsVirtual() throws {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
            .ioregDeviceTree: .ok(try collectorFixture("ioreg-iomedia-tree-internal-apfs.txt")),
        ])

        let collection = DeviceCollector(executor: executor).collect(bsd: "disk3")

        #expect(collection.status == .ok)
        #expect(collection.identity?.virtualOrPhysical == "Virtual",
                "the APFS container is never a physical probe source")
    }
}
