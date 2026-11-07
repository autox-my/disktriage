import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors
import DiskTriageCLI

/// P1e: the live pipeline, driven end to end through the injected process
/// layer. No subprocess, no raw device, no hardware.
struct LiveCLITests {

    // REQ-0058: progress on stderr, verdict on stdout.
    @Test("REQ0058 live triage disk0 runs the pipeline and keeps stdout for the verdict")
    func REQ0058_liveTriageRunsThePipeline() {
        let executor = CLIExecutor { command in
            switch command {
            case .diskutilInfo:
                return .ok(fixtureText("diskutil-info-internal.plist"))
            case .ioregStatistics:
                return .ok(fixtureText("ioreg-internal-driver.txt"))
            case .ioregMedia:
                return .ok(fixtureText("ioreg-iomedia-internal.txt"))
            case .logShow:
                return .ok(fixtureText("kernel-log-healthy-compact.txt"))
            case .smartctl:
                return .ok(#"{"smartctl":{"exit_status":0}}"#)
            default:
                return .ok("")
            }
        }

        let result = run(arguments: ["triage", "disk0"], executor: executor)

        #expect(result.exitCode == 20, "unsupported internal SSD is exit 20")
        #expect(result.stdout.contains("triage not applicable"), "no health classification")
        #expect(result.stdout.contains("disktriage image disk0"), "imaging is still offered")
        #expect(!result.stdout.contains("disktriage: collecting"), "no progress on stdout")
        #expect(result.stderr.contains("collecting disk0"), "progress is on stderr")
        #expect(executor.commands.contains { if case .logShow = $0 { return true }; return false },
                "the live pipeline queried the log")
    }

    @Test("the default log window is 1h and --log-window reaches the command")
    func theLogWindowReachesTheCommand() {
        let executor = standardExecutor()
        _ = run(arguments: ["triage", "disk0"], executor: executor)
        _ = run(arguments: ["triage", "disk0", "--log-window", "12h"], executor: executor)

        let logs = executor.commands.compactMap { command -> (String, String)? in
            guard case .logShow(let last, let predicate) = command else { return nil }
            return (last, predicate)
        }
        #expect(logs.count == 2, "one log query per run")
        #expect(logs.first?.0 == "1h", "the default window")
        #expect(logs.last?.0 == "12h", "the requested window")
        #expect(logs.allSatisfy { $0.1 == KernelLogCollector.predicate },
                "the query is the kernel predicate, not a per-disk one")
    }

    // REQ-0011 / REQ-0012: one collector's timeout never blocks the others and
    // is a status, not a crash.
    @Test("REQ0011_REQ0012 a SMART timeout does not stop the other collectors")
    func REQ0011_REQ0012_aSmartTimeoutDoesNotStopTheOthers() {
        let executor = standardExecutor(smart: .timeout())
        var written: [String: Data] = [:]
        let result = run(
            arguments: ["triage", "disk0", "--record", "/tmp/disk0.json"],
            writeFile: { path, data in written[path] = data },
            executor: executor
        )

        #expect(result.exitCode == 20, "the device verdict still forms")
        for command in [TriageCommand.ioregStatistics, .ioregMedia] {
            #expect(executor.commands.contains(command), "\(command) still ran")
        }
        #expect(executor.commands.contains { if case .logShow = $0 { return true }; return false },
                "the log collector still ran")

        let data = written["/tmp/disk0.json"]
        #expect(data != nil, "the recording was written")
        let set = try? JSONDecoder.disktriage().decode(SignalSet.self, from: data ?? Data())
        #expect(set?.smart?.status == .timeout, "SMART is a timeout status")
        #expect(set?.smart?.pending == nil, "a timeout is not zero counters")
    }

    // REQ-0023: unsupported SMART keeps nil counters.
    @Test("REQ0023 an unsupported SMART recording keeps nil counters in --record")
    func REQ0023_unsupportedSmartKeepsNilCounters() {
        let unsupported = CollectorResult(
            outcome: .error,
            exitCode: 1,
            stdout: fixtureText("smart-unsupported-not-scsi.json")
        )
        var written = Data()
        _ = run(
            arguments: ["triage", "disk0", "--record", "/tmp/disk0.json"],
            writeFile: { _, data in written = data },
            executor: standardExecutor(smart: unsupported)
        )

        let set = try? JSONDecoder.disktriage().decode(SignalSet.self, from: written)
        #expect(set?.smart?.status == .unsupported, "status")
        #expect(set?.smart?.pending == nil, "pending is nil")
        #expect(set?.smart?.reallocated == nil, "reallocated is nil")
    }

    @Test("unknown media over USB is triaged, not labelled unsupported")
    func unknownMediaOverUSBIsTriaged() {
        let executor = standardExecutor(info: fixtureText("diskutil-info-usb-unknown.plist"))
        let result = run(arguments: ["triage", "disk8", "--json"], executor: executor)

        #expect(result.exitCode != 20 || !result.stdout.contains("unsupported media"),
                "unknown media must not take the unsupported branch: \(result.stdout)")
        #expect(!result.stdout.contains("\"unsupported\" : \"UNSUPPORTED"),
                "no unsupported note for unknown USB media")
    }

    // REQ-0053 / REQ-0054: list labels unsupported media and shows no health line.
    @Test("REQ0053_REQ0054 list shows one line per disk and never a health judgement")
    func REQ0053_REQ0054_listLabelsUnsupportedMedia() {
        let result = run(arguments: ["list"], executor: listExecutor())

        #expect(result.exitCode == 0, "listing is not a verdict")
        #expect(result.stdout.contains("disk0"), "the internal disk")
        #expect(result.stdout.contains("disk8"), "the USB disk")
        #expect(result.stdout.contains("triage not applicable"), "the internal SSD label")
        #expect(result.stdout.contains("triage applicable"), "the USB HDD is triageable")
        #expect(!result.stdout.contains("disk1"), "a synthesized APFS container is not a physical disk")
        let lowered = result.stdout.lowercased()
        #expect(!lowered.contains("healthy"), "never the word healthy")
        #expect(!lowered.contains("health"), "never a health judgement")
        #expect(!lowered.contains("passed"), "never a SMART verdict in list")
    }

    @Test("REQ0056 list --json carries the same fields")
    func REQ0056_listJSONCarriesTheFields() throws {
        let result = run(arguments: ["list", "--json"], executor: listExecutor())

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]],
            "an array of disks"
        )
        #expect(object.count == 2, "two whole disks, no slices")
        let internalDisk = try #require(object.first { $0["bsd"] as? String == "disk0" }, "disk0")
        #expect(internalDisk["model"] as? String == "APPLE SSD AP0256Q", "model")
        #expect(internalDisk["triage"] as? String == "not_applicable", "unsupported label")
        #expect(internalDisk["internal"] as? Bool == true, "internal")
        let usb = try #require(object.first { $0["bsd"] as? String == "disk8" }, "disk8")
        #expect(usb["triage"] as? String == "applicable", "triage applies")
        #expect(usb["internal"] as? Bool == false, "external")
    }

    // REQ-0060: --record writes only the requested path and hashes the serial.
    @Test("REQ0010_REQ0060 --record writes only its file and hashes the serial")
    func REQ0010_REQ0060_recordRedactsTheSerial() throws {
        var writes: [(String, Data)] = []
        let result = run(
            arguments: ["triage", "--from", fixturePath("minah.json"), "--record", "/tmp/minah.record.json"],
            writeFile: { path, data in writes.append((path, data)) }
        )

        #expect(result.exitCode == 10, "the verdict is unchanged")
        #expect(writes.count == 1, "one write, nowhere else")
        #expect(writes.first?.0 == "/tmp/minah.record.json", "the requested path")
        let data = try #require(writes.first?.1, "the written bytes")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("WD-WX0123456789"), "the raw serial is gone")
        let set = try JSONDecoder.disktriage().decode(SignalSet.self, from: data)
        let serial = try #require(set.device?.serial, "a hashed serial")
        #expect(serial.count == 64, "SHA-256 hex")
        #expect(serial.allSatisfy { $0.isHexDigit }, "hex")
        #expect(set.smart?.pending == 131, "the measurements survive")
    }
}

// MARK: - Scripted process layer

final class CLIExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (TriageCommand) -> CollectorResult
    private var recorded: [TriageCommand] = []

    init(_ handler: @escaping (TriageCommand) -> CollectorResult) {
        self.handler = handler
    }

    var commands: [TriageCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ command: TriageCommand) -> CollectorResult {
        lock.lock()
        recorded.append(command)
        lock.unlock()
        return handler(command)
    }
}

private func standardExecutor(
    info: String = fixtureText("diskutil-info-internal.plist"),
    smart: CollectorResult = .ok(#"{"smartctl":{"exit_status":0}}"#)
) -> CLIExecutor {
    CLIExecutor { command in
        switch command {
        case .diskutilInfo:
            return .ok(info)
        case .ioregStatistics:
            return .ok(fixtureText("ioreg-internal-driver.txt"))
        case .ioregMedia:
            return .ok(fixtureText("ioreg-iomedia-internal.txt"))
        case .logShow:
            return .ok(fixtureText("kernel-log-healthy-compact.txt"))
        case .smartctl:
            return smart
        default:
            return .ok("")
        }
    }
}

private func listExecutor() -> CLIExecutor {
    let list = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>AllDisks</key>
      <array>
        <string>disk0</string><string>disk0s1</string>
        <string>disk1</string><string>disk1s1</string>
        <string>disk8</string><string>disk8s1</string>
      </array>
    </dict></plist>
    """
    return CLIExecutor { command in
        switch command {
        case .diskutilList:
            return .ok(list)
        case .diskutilInfo(let disk):
            switch disk {
            case "disk0":
                return .ok(fixtureText("diskutil-info-internal.plist"))
            case "disk1":
                return .ok(fixtureText("diskutil-info-virtual-apfs.plist"))
            default:
                return .ok(fixtureText("diskutil-info-usb-unknown.plist"))
            }
        default:
            return .ok("")
        }
    }
}

private func fixtureText(_ name: String) -> String {
    (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
}
