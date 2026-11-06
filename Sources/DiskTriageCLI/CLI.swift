import Foundation
import CryptoKit
import DiskTriageCore
import DiskTriageCollectors

/// What the CLI produced: the two streams and the process exit code. Nothing
/// is printed here, so a test can assert both streams exactly.
public struct CLIResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// The usage-error code. The plan is silent on it; 2 is req's usage code and
/// collides with no verdict or collection code (0, 10–13, 20, 21, 30).
public let usageExitCode: Int32 = 2

/// The CLI as a library, so the whole command surface is testable without a
/// process. Reading a file, writing a recording and the process layer are
/// injected; `DiskTriageCore` stays pure.
public func run(
    arguments: [String],
    readFile: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
    writeFile: (String, Data) throws -> Void = { path, data in
        try data.write(to: URL(fileURLWithPath: path))
    },
    executor: any CommandExecuting = ProcessRunner(timeout: 30),
    now: () -> Date = Date.init
) -> CLIResult {
    guard let command = arguments.first else {
        return rootHelp()
    }

    let rest = Array(arguments.dropFirst())
    switch command {
    case "--help", "-h", "help":
        return rootHelp()
    case "triage":
        return triage(rest, readFile: readFile, writeFile: writeFile, executor: executor, now: now)
    case "list":
        return list(rest, executor: executor)
    case "image", "inspect", "copy", "check", "guard":
        return planned(command, rest)
    default:
        return usageError("unknown command '\(command)'")
    }
}

// MARK: - triage

private func triage(
    _ arguments: [String],
    readFile: (String) throws -> Data,
    writeFile: (String, Data) throws -> Void,
    executor: any CommandExecuting,
    now: () -> Date
) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(triageUsage)
    }

    var from: String?
    var record: String?
    var disk: String?
    var window = KernelLogCollector.defaultWindow
    var asJSON = false
    var local = false
    var index = 0

    while index < arguments.count {
        switch arguments[index] {
        case "--from":
            guard index + 1 < arguments.count else {
                return usageError("--from needs a SignalSet file path")
            }
            from = arguments[index + 1]
            index += 2
        case "--record":
            guard index + 1 < arguments.count else {
                return usageError("--record needs a file path")
            }
            record = arguments[index + 1]
            index += 2
        case "--log-window":
            guard index + 1 < arguments.count else {
                return usageError("--log-window needs a value such as 1h")
            }
            let value = arguments[index + 1]
            guard KernelLogCollector.windowHours(value) != nil else {
                return usageError("--log-window '\(value)' is not a window such as 6h, 30m or 2d")
            }
            window = value
            index += 2
        case "--json":
            asJSON = true
            index += 1
        case "--local":
            local = true
            index += 1
        default:
            let argument = arguments[index]
            if argument.hasPrefix("-") {
                return usageError("unknown option '\(argument)'")
            }
            guard disk == nil else {
                return usageError("triage takes one disk, not '\(argument)'")
            }
            guard isWholeDiskName(argument) else {
                return usageError("'\(argument)' is not a whole disk name (for example disk4)")
            }
            disk = argument
            index += 1
        }
    }

    if from != nil && disk != nil {
        return usageError("triage takes a disk or --from, not both")
    }
    guard from != nil || disk != nil else {
        return usageError("triage needs a disk to collect, or --from <signalset.json>")
    }

    var progress: [String] = []

    let signals: SignalSet
    if let from {
        let data: Data
        do {
            data = try readFile(from)
        } catch {
            return CLIResult(
                stdout: "",
                stderr: "disktriage: cannot read \(from): \(error.localizedDescription)\n",
                exitCode: 30
            )
        }
        do {
            signals = try JSONDecoder.disktriage().decode(SignalSet.self, from: data)
        } catch {
            return CLIResult(
                stdout: "",
                stderr: "disktriage: malformed SignalSet JSON in \(from): \(error)\n",
                exitCode: 30
            )
        }
        progress.append("disktriage: reading \(from)")
    } else if let disk {
        guard let live = collectLive(disk: disk, window: window, executor: executor, now: now, progress: &progress) else {
            return CLIResult(
                stdout: "",
                stderr: progress.joined(separator: "\n") + "\n"
                    + "disktriage: cannot assemble a SignalSet for \(disk)\n",
                exitCode: 30
            )
        }
        signals = live
    } else {
        return usageError("triage needs a disk to collect, or --from <signalset.json>")
    }

    if let record {
        let redacted = signals.redacted(serialHash: sha256Hex)
        do {
            try writeFile(record, try encode(redacted))
            progress.append("disktriage: recorded a redacted SignalSet to \(record)")
        } catch {
            return CLIResult(
                stdout: "",
                stderr: progress.joined(separator: "\n") + "\n"
                    + "disktriage: cannot write \(record): \(error.localizedDescription)\n",
                exitCode: 30
            )
        }
    }

    // A recorded set has no live device, so the suggested image destination is
    // derived from its name; the Appendix's transcript was rendered that way.
    let destination = from.map { "/Volumes/Scratch/\(fileStem($0)).img" }
        ?? "/Volumes/Scratch/\(fileStem(signals.device?.bsd ?? "image")).img"
    let verdict = classify(signals, context: TriageContext(imageDestination: destination))
    let stdout = asJSON
        ? Renderer.json(verdict)
        : Renderer.tty(
            signals,
            verdict,
            timeZone: local ? TimeZone.current : TimeZone(secondsFromGMT: 0)!
        )
    let device = signals.device?.bsd ?? "unknown device"
    progress.append("disktriage: classified \(device) as exit \(verdict.code.rawValue)")

    return CLIResult(
        stdout: stdout,
        stderr: progress.joined(separator: "\n") + "\n",
        exitCode: Int32(verdict.code.rawValue)
    )
}

/// Collects every section in a deterministic order. Each collector returns a
/// status instead of throwing, so one timeout, denial or parse failure never
/// stops the sections after it (REQ-0011, REQ-0012).
private func collectLive(
    disk: String,
    window: String,
    executor: any CommandExecuting,
    now: () -> Date,
    progress: inout [String]
) -> SignalSet? {
    progress.append("disktriage: collecting \(disk) (device, io, log, smart)")

    let device = DeviceCollector(executor: executor).collect(bsd: disk)
    let io = IOStatsCollector(executor: executor).collect(bsd: disk)
    let log = KernelLogCollector(executor: executor).collect(bsd: disk, window: window)
    let smart = SmartCollector(executor: executor).collect(bsd: disk)

    progress.append(
        "disktriage: device \(device.status.rawValue) · io \(io.status.rawValue)"
            + " · log \(log.status.rawValue) · smart \(smart.status.rawValue)"
    )

    var builder = SignalSetBuilder(collectedAt: now())
    builder.setDevice(device)
    builder.setIO(io)
    builder.setLog(log)
    builder.setSmart(smart)
    return try? builder.build()
}

// MARK: - list

private func list(_ arguments: [String], executor: any CommandExecuting) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(listUsage)
    }

    var asJSON = false
    for argument in arguments {
        switch argument {
        case "--json":
            asJSON = true
        default:
            return usageError("unknown option '\(argument)'")
        }
    }

    let collector = DeviceCollector(executor: executor)
    let enumeration = collector.enumerate()
    guard enumeration.status == .ok else {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: cannot enumerate disks: "
                + (enumeration.reason ?? enumeration.status.rawValue) + "\n",
            exitCode: 30
        )
    }

    var rows: [ListRow] = []
    for bsd in enumeration.disks {
        let collection = collector.collect(bsd: bsd)
        // A synthesized APFS container or a disk image is not a physical disk.
        if collection.identity?.virtualOrPhysical?.lowercased() == "virtual" {
            continue
        }
        rows.append(ListRow(bsd: bsd, collection: collection))
    }

    if asJSON {
        let objects: [[String: Any]] = rows.map { row in
            var object: [String: Any] = ["bsd": row.bsd]
            if let identity = row.identity {
                if let size = identity.sizeBytes { object["size_bytes"] = size }
                if let model = identity.model { object["model"] = model }
                if let bus = identity.bus { object["bus"] = bus }
                if let internalDisk = identity.internalDisk { object["internal"] = internalDisk }
            }
            object["triage"] = row.triageValue
            return object
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return CLIResult(stdout: "", stderr: "disktriage: cannot render the disk list\n", exitCode: 30)
        }
        return CLIResult(stdout: text + "\n", stderr: "", exitCode: 0)
    }

    var lines = [
        pad("DISK", 7) + pad("MODEL", 31) + pad("SIZE", 12) + pad("BUS", 7)
            + pad("LOCATION", 10) + "TRIAGE"
    ]
    lines += rows.map(\.line)
    return CLIResult(stdout: lines.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
}

private struct ListRow {
    let bsd: String
    let identity: DeviceIdentity?
    let status: SignalStatus
    /// The machine value: `applicable`, `not_applicable` or `unavailable`.
    let triageValue: String
    /// The tty wording from diskdoctor.md §6.
    let triageLabel: String

    init(bsd: String, collection: DeviceCollection) {
        self.bsd = bsd
        self.identity = collection.identity
        self.status = collection.status
        if collection.status == .ok, let identity = collection.identity {
            let unsupported = MediaSupport.unsupportedLabel(media: identity.media, bus: identity.bus) != nil
            self.triageValue = unsupported ? "not_applicable" : "applicable"
            self.triageLabel = unsupported ? "triage not applicable" : "triage applicable"
        } else {
            self.triageValue = "unavailable"
            self.triageLabel = "unavailable (\(collection.status.rawValue))"
        }
    }

    var line: String {
        guard status == .ok, let identity else {
            return pad(bsd, 7) + pad("-", 31) + pad("-", 12) + pad("-", 7)
                + pad("-", 10) + triageLabel
        }
        let location: String
        switch identity.internalDisk {
        case .some(true): location = "internal"
        case .some(false): location = "external"
        case .none: location = "unknown"
        }
        return pad(bsd, 7)
            + pad(identity.model ?? "unknown", 31)
            + pad(sizeText(identity.sizeBytes), 12)
            + pad(identity.bus ?? "unknown", 7)
            + pad(location, 10)
            + triageLabel
    }
}

private func sizeText(_ bytes: Int64?) -> String {
    guard let bytes else { return "unknown" }
    return String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
}

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}

// MARK: - Recording

private func encode(_ signals: SignalSet) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(signals)
}

private func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

// MARK: - Planned commands

/// Every other command is deliberately unimplemented: it says so and exits 30,
/// so a script can never mistake it for a working run (diskdoctor.md §6).
private func planned(_ command: String, _ arguments: [String]) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(
            "usage: disktriage \(command) [options]\n\n"
                + "Not implemented yet (planned P2/P3). See diskdoctor.md §6.\n"
        )
    }
    return CLIResult(
        stdout: "",
        stderr: "disktriage: \(command) is not implemented yet (planned P2/P3)\n",
        exitCode: 30
    )
}

// MARK: - Help and usage

private func help(_ text: String) -> CLIResult {
    CLIResult(stdout: text, stderr: "", exitCode: 0)
}

private func rootHelp() -> CLIResult {
    help(
        "usage: disktriage <command> [options]\n"
            + "\n"
            + "commands:\n"
            + "  triage <disk>   classify a device, or --from <signalset.json>\n"
            + "  list            list whole disks; no health judgement\n"
            + "  image    image a device to a file           (planned P2)\n"
            + "  inspect  inspect an image read-only         (planned P2)\n"
            + "  copy     copy an image with a manifest      (planned P3)\n"
            + "  check    permissions and tooling self-test  (planned P2)\n"
            + "  guard    hold mounts for attached disks     (planned P2)\n"
            + "\n"
            + "Run 'disktriage <command> --help' for options.\n"
    )
}

private let triageUsage = "usage: disktriage triage <disk> [--json] [--local] [--record <file>] [--log-window <1h>]\n"
    + "       disktriage triage --from <signalset.json> [--json] [--local] [--record <file>]\n"
    + "\n"
    + "Collects the read-only signals for one whole disk: diskutil identity,\n"
    + "ioreg I/O counters and the IOMedia association, the unified log and SMART.\n"
    + "\n"
    + "  --from <file>       classify a recorded SignalSet instead of a live disk\n"
    + "  --record <file>     write a redacted SignalSet (serial hashed) to this file only\n"
    + "  --log-window <w>    unified-log window, default 1h (log show --last form)\n"
    + "  --json              print the verdict as JSON instead of the tty transcript\n"
    + "  --local             render log timestamps in the local zone (default UTC)\n"

private let listUsage = "usage: disktriage list [--json]\n"
    + "\n"
    + "Lists whole physical disks with size, model, bus and internal/external.\n"
    + "Unsupported media are labelled 'triage not applicable'; list never makes a\n"
    + "health judgement.\n"

private func usageError(_ message: String) -> CLIResult {
    CLIResult(
        stdout: "",
        stderr: "disktriage: \(message)\n"
            + "usage: disktriage <command> [options]  (see --help)\n",
        exitCode: usageExitCode
    )
}

// MARK: - Input

private func fileStem(_ path: String) -> String {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return name.isEmpty ? "image" : name
}

private func isWholeDiskName(_ name: String) -> Bool {
    guard name.hasPrefix("disk") else { return false }
    let digits = name.dropFirst(4)
    return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
}
