import Foundation
import CryptoKit
import DiskTriageCore
import DiskTriageCollectors
import DiskTriageGuard

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
    writeFile: @escaping (String, Data) throws -> Void = { path, data in
        try data.write(to: URL(fileURLWithPath: path))
    },
    executor: any CommandExecuting = ProcessRunner(timeout: 30),
    now: @escaping () -> Date = Date.init,
    destinationProbe: (any ImageDestinationProbing)? = nil,
    imaging: ImagingDependencies? = nil,
    inspectDependencies: InspectDependencies? = nil,
    copyDependencies: CopyDependencies? = nil,
    historyStore: (any SnapshotStoring)? = nil
) -> CLIResult {
    guard let command = arguments.first else {
        return rootHelp()
    }

    let rest = Array(arguments.dropFirst())
    switch command {
    case "--help", "-h", "help":
        return rootHelp()
    case "--version", "version":
        return help("disktriage \(DisktriageVersion.current)\n")
    case "triage":
        return triage(
            rest,
            readFile: readFile,
            writeFile: writeFile,
            executor: executor,
            now: now,
            historyStore: historyStore
        )
    case "list":
        return list(rest, executor: executor)
    case "image":
        return image(
            rest,
            executor: executor,
            now: now,
            destinationProbe: destinationProbe,
            writeFile: writeFile,
            imaging: imaging
        )
    case "check":
        return runCheck(arguments: rest)
    case "guard":
        let result = runGuard(arguments: rest)
        return CLIResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    case "inspect":
        return runInspect(arguments: rest, dependencies: inspectDependencies)
    case "copy":
        return runCopy(arguments: rest, dependencies: copyDependencies)
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
    now: () -> Date,
    historyStore: (any SnapshotStoring)?
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
    var noHistory = false
    var historyDirectory: String?
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
        case "--no-history":
            noHistory = true
            index += 1
        case "--history-dir":
            guard index + 1 < arguments.count else {
                return usageError("--history-dir needs a directory path")
            }
            historyDirectory = arguments[index + 1]
            index += 2
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

    // Local history is a live-only signal: a recorded set carries whatever
    // history it was given and must never read or write the store (REQ-0159).
    let snapshotTime = now()
    var classifiedSignals = signals
    var storeToWrite: (any SnapshotStoring)?
    var pendingSnapshot: SnapshotRecord?
    var snapshotStatus: SignalStatus?
    if from == nil {
        let serial = signals.device?.serial.flatMap { $0.isEmpty ? nil : $0 }
        let smartStatus = signals.smart?.status
        if noHistory {
            progress.append("disktriage: history: disabled (--no-history)")
        } else if serial == nil {
            progress.append(
                "disktriage: history: unavailable (no serial; no history read or snapshot written)"
            )
        } else if smartStatus != .ok {
            let status = smartStatus?.rawValue ?? "not collected"
            progress.append(
                "disktriage: history: unavailable (SMART \(status) is not a measurement; "
                    + "no snapshot read or written)"
            )
        } else {
            let key = SnapshotStore.key(forSerial: serial ?? "")
            let store = historyStore ?? SnapshotStore(directory: resolvedHistoryDirectory(historyDirectory))
            let prior = store.loadPrior(key: key, before: snapshotTime)
            for note in prior.notes {
                progress.append("disktriage: history: \(note)")
            }
            if let history = SnapshotHistory.history(from: prior.record, forKey: key) {
                classifiedSignals = signals.attachingSmartHistory(history)
                progress.append(
                    "disktriage: history: used (prior snapshot recorded \(historyStamp(history.recordedAt)))"
                )
            } else {
                progress.append("disktriage: history: first sight (no prior snapshot for this device)")
            }
            pendingSnapshot = SnapshotHistory.record(from: signals, deviceKey: key, recordedAt: snapshotTime)
            storeToWrite = store
            snapshotStatus = smartStatus
        }
    }

    // A recorded set has no live device, so the suggested image destination is
    // derived from its name; the Appendix's transcript was rendered that way.
    let destination = from.map { "/Volumes/Scratch/\(fileStem($0)).img" }
        ?? "/Volumes/Scratch/\(fileStem(signals.device?.bsd ?? "image")).img"
    let verdict = classify(classifiedSignals, context: TriageContext(imageDestination: destination))
    let stdout = asJSON
        ? Renderer.json(verdict)
        : Renderer.tty(
            classifiedSignals,
            verdict,
            timeZone: local ? TimeZone.current : TimeZone(secondsFromGMT: 0)!
        )

    // The snapshot is written after classification, and a write failure is a
    // note on stderr: it never changes the verdict or the exit code
    // (REQ-0160).
    if let store = storeToWrite {
        if let record = pendingSnapshot {
            switch store.save(record) {
            case .written:
                progress.append("disktriage: history: snapshot stored")
            case .skipped(let reason):
                progress.append("disktriage: history: snapshot not stored (\(reason))")
            case .failed(let reason):
                progress.append(
                    "disktriage: history: snapshot not stored (\(reason)); the verdict is unchanged"
                )
            }
        } else {
            let status = snapshotStatus?.rawValue ?? "not collected"
            progress.append("disktriage: history: not stored (SMART \(status) is not a measurement)")
        }
    }

    let device = signals.device?.bsd ?? "unknown device"
    progress.append("disktriage: classified \(device) as exit \(verdict.code.rawValue)")

    return CLIResult(
        stdout: stdout,
        stderr: progress.joined(separator: "\n") + "\n",
        exitCode: Int32(verdict.code.rawValue)
    )
}

/// `--history-dir`, then `DISKTRIAGE_HISTORY_DIR`, then the documented default.
private func resolvedHistoryDirectory(_ flag: String?) -> URL {
    SnapshotStore.resolveDirectory(
        flag: flag,
        environment: ProcessInfo.processInfo.environment,
        fallback: SnapshotStore.defaultDirectory()
    )
}

private func historyStamp(_ date: Date?) -> String {
    guard let date else { return "at an unknown time" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// Collects every section in a deterministic order. Each collector returns a
/// status instead of throwing, so one timeout, denial or parse failure never
/// stops the sections after it (REQ-0011, REQ-0012).
func collectLive(
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

// MARK: - Help and usage

func help(_ text: String) -> CLIResult {
    CLIResult(stdout: text, stderr: "", exitCode: 0)
}

private func rootHelp() -> CLIResult {
    help(
        "usage: disktriage <command> [options]\n"
            + "\n"
            + "commands:\n"
            + "  triage <disk>   classify a device, or --from <signalset.json>\n"
            + "  list            list whole disks; no health judgement\n"
            + "  image    image a device to a file (dry-run default)\n"
            + "  inspect  inspect an image read-only (NTFS, APFS, HFS+, exFAT, FAT)\n"
            + "  copy     copy a volume's files with a hashed manifest\n"
            + "  check    permissions and tooling self-test\n"
            + "  guard    hold mounts; start it before connecting the disk\n"
            + "\n"
            + "  --version       print 'disktriage <version>'\n"
            + "\n"
            + "Run 'disktriage <command> --help' for options.\n"
    )
}

private let triageUsage = "usage: disktriage triage <disk> [--json] [--local] [--record <file>]\n"
    + "                            [--log-window <1h>] [--no-history] [--history-dir <path>]\n"
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
    + "  --no-history        do not read or write the local SMART snapshot store\n"
    + "  --history-dir <p>   snapshot directory (default ~/Library/Application\n"
    + "                      Support/disktriage/history; DISKTRIAGE_HISTORY_DIR also\n"
    + "                      overrides it)\n"

private let listUsage = "usage: disktriage list [--json]\n"
    + "\n"
    + "Lists whole physical disks with size, model, bus and internal/external.\n"
    + "Unsupported media are labelled 'triage not applicable'; list never makes a\n"
    + "health judgement.\n"

func usageError(_ message: String) -> CLIResult {
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

func isWholeDiskName(_ name: String) -> Bool {
    guard name.hasPrefix("disk") else { return false }
    let digits = name.dropFirst(4)
    return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
}
