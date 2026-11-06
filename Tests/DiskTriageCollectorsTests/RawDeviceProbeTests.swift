import Foundation
import Testing
import DiskTriageCore
@testable import DiskTriageCollectors

/// P2b: the probe reads the internal disk's raw node with a 4096-byte
/// block-aligned read (docs/p0-runbook.md row 8), and no test opens a device.
struct RawDeviceProbeTests {

    @Test("the probe asks for 4096 bytes, never the plan's old 512")
    func probeAsksFor4096Bytes() {
        let recorder = ProbeRecorder()
        let probe = RawDeviceProbe { node, count in
            recorder.record(node: node, count: count)
            return .read(bytes: count)
        }

        let evidence = probe.probe(node: "/dev/rdisk0")

        #expect(recorder.node == "/dev/rdisk0", "the internal raw node")
        #expect(recorder.count == 4096, "the measured block-aligned size, not 512")
        #expect(evidence == .read(bytes: 4096), "the evidence is returned unchanged")
    }

    @Test("an internal disk is found through diskutil; a virtual container is skipped")
    func internalDiskIsFoundAndVirtualContainersAreSkipped() {
        let list = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>AllDisks</key>
          <array>
            <string>disk0</string><string>disk0s1</string>
            <string>disk1</string><string>disk4</string>
          </array>
        </dict></plist>
        """

        let locator = InternalDiskLocator(executor: DiskSwitchExecutor(list: .ok(list), info: [
            // A synthesized container that claims to be internal.
            "disk0": .ok(Self.plist(bsd: "disk0", internal: true, virtual: "Virtual")),
            "disk1": .ok(Self.plist(bsd: "disk1", internal: true, virtual: "Virtual")),
            "disk4": .ok(Self.plist(bsd: "disk4", internal: true, virtual: "Physical")),
        ]))

        #expect(locator.internalRawNode() == "/dev/rdisk4", "the first real internal disk")
    }

    @Test("no internal disk means no node, never a fallback to a suspect device")
    func noInternalDiskMeansNoNode() {
        let list = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>AllDisks</key><array><string>disk8</string></array></dict></plist>
        """
        let locator = InternalDiskLocator(executor: DiskSwitchExecutor(
            list: .ok(list),
            info: ["disk8": .ok(Self.plist(bsd: "disk8", internal: false, virtual: "Physical"))]
        ))
        #expect(locator.internalRawNode() == nil, "an external disk is not the probe source")
    }

    private static func plist(bsd: String, internal isInternal: Bool, virtual: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>DeviceIdentifier</key><string>\(bsd)</string>
          <key>Internal</key><\(isInternal)/>
          <key>VirtualOrPhysical</key><string>\(virtual)</string>
          <key>DeviceBlockSize</key><integer>4096</integer>
        </dict></plist>
        """
    }
}

final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedNode: String?
    private var recordedCount: Int?

    var node: String? {
        lock.lock(); defer { lock.unlock() }
        return recordedNode
    }

    var count: Int? {
        lock.lock(); defer { lock.unlock() }
        return recordedCount
    }

    func record(node: String, count: Int) {
        lock.lock()
        recordedNode = node
        recordedCount = count
        lock.unlock()
    }
}

/// Answers `diskutil info` per disk; everything else is empty.
struct DiskSwitchExecutor: CommandExecuting {
    let list: CollectorResult
    let info: [String: CollectorResult]

    func run(_ command: TriageCommand) -> CollectorResult {
        switch command {
        case .diskutilList:
            return list
        case .diskutilInfo(let disk):
            return info[disk] ?? .ok("")
        default:
            return .ok("")
        }
    }
}
