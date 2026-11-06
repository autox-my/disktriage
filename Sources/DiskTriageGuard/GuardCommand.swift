import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// `disktriage guard` — the mount guard from diskdoctor.md section 8.
///
/// Two modes, both started before the disk is connected (REQ-0072):
/// - `dissent` (default): a DiskArbitration mount-approval callback returns
///   `kDAReturnExclusiveAccess` for external physical disks. The measured
///   limit is that this stops the mount, not the driver's probe reads (P0 row 5).
/// - `--suspend`: SIGSTOP diskarbitrationd for the session, which stops both
///   probe and mount, at the cost of `diskutil` and Finder disk handling
///   hanging system-wide while it is stopped.
///
/// Nothing here mounts, unmounts or ejects anything, and a signal is only ever
/// sent through the injected `ProcessSignaling` seam.
public enum GuardMode: String, Equatable, Sendable {
    case dissent
    case suspend
}

public struct GuardOptions: Equatable, Sendable {
    public var mode: GuardMode
    public var seconds: Double?
    public var json: Bool
    public var observe: Bool

    public init(
        mode: GuardMode = .dissent,
        seconds: Double? = nil,
        json: Bool = false,
        observe: Bool = false
    ) {
        self.mode = mode
        self.seconds = seconds
        self.json = json
        self.observe = observe
    }
}

public enum GuardParseResult: Equatable, Sendable {
    case options(GuardOptions)
    case help
    case usage(String)
}

/// The project's usage code; it collides with no verdict or collection code
/// (docs/sdlc.md). DiskTriageCLI has the same constant for every command.
public let guardUsageExitCode: Int32 = 2

/// Whether protection is actually in effect, as printed on the first line.
/// It is never derived from hope: root plus a registered callback is ACTIVE,
/// and every refusal carries its reason.
public enum GuardProtection: Equatable, Sendable {
    case active
    case notActive(String)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// "protection: ACTIVE" or "protection: NOT ACTIVE (reason)".
    public var text: String {
        switch self {
        case .active: return "protection: ACTIVE"
        case .notActive(let reason): return "protection: NOT ACTIVE (\(reason))"
        }
    }
}

/// The CLI result for the guard command. Runtime lines are streamed through
/// `GuardOutput` (a daemon must flush each decision); help and usage, which are
/// immediate, come back as strings so the CLI wrapper can print them.
public struct GuardCLIResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum GuardStream: Sendable {
    case out
    case err
}

/// One line at a time, flushed. The live sink writes straight to the standard
/// streams so a decision is visible the moment it is made; the recorder is for
/// the suite.
public struct GuardOutput: Sendable {
    let write: @Sendable (GuardStream, String) -> Void

    public init(write: @escaping @Sendable (GuardStream, String) -> Void) {
        self.write = write
    }

    public func line(_ stream: GuardStream, _ text: String) {
        write(stream, text.hasSuffix("\n") ? text : text + "\n")
    }

    public static let live = GuardOutput { stream, text in
        switch stream {
        case .out:
            FileHandle.standardOutput.write(Data(text.utf8))
        case .err:
            FileHandle.standardError.write(Data(text.utf8))
        }
    }
}

public final class GuardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []

    public init() {}

    public var stdout: [String] {
        lock.lock(); defer { lock.unlock() }
        return out
    }

    public var stderr: [String] {
        lock.lock(); defer { lock.unlock() }
        return err
    }

    func append(_ stream: GuardStream, _ text: String) {
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .out: out.append(line)
        case .err: err.append(line)
        }
    }

    public var output: GuardOutput {
        GuardOutput { [self] stream, text in append(stream, text) }
    }
}

// MARK: - Parsing

public func parseGuardArguments(_ arguments: [String]) -> GuardParseResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return .help
    }

    var options = GuardOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--suspend":
            options.mode = .suspend
            index += 1
        case "--json":
            options.json = true
            index += 1
        case "--observe":
            options.observe = true
            index += 1
        case "--seconds":
            guard index + 1 < arguments.count else {
                return .usage("--seconds needs a value in seconds")
            }
            let raw = arguments[index + 1]
            guard let value = positiveSeconds(raw) else {
                return .usage("--seconds '\(raw)' is not a positive number of seconds")
            }
            options.seconds = value
            index += 2
        default:
            guard argument.hasPrefix("--seconds=") else {
                return .usage("unknown option '\(argument)'")
            }
            let raw = String(argument.dropFirst("--seconds=".count))
            guard let value = positiveSeconds(raw) else {
                return .usage("--seconds '\(raw)' is not a positive number of seconds")
            }
            options.seconds = value
            index += 1
        }
    }

    if options.observe {
        guard options.seconds != nil else {
            return .usage("--observe needs --seconds N: an observation has a bound")
        }
        if options.mode == .suspend {
            return .usage("--observe is dissent-mode only; --suspend is never observation-only")
        }
    }
    return .options(options)
}

private func positiveSeconds(_ text: String) -> Double? {
    guard let value = Double(text), value > 0, value.isFinite else { return nil }
    return value
}

// MARK: - Command

@discardableResult
public func runGuard(
    arguments: [String],
    isRoot: Bool = getuid() == 0,
    dissent: any DissentRunning = DiskArbitrationDissent(),
    signaling: any ProcessSignaling = LiveProcessSignaling(),
    nodes: any RawDiskNodeProviding = LiveRawDiskNodes(),
    waiting: any GuardWaiting = LiveGuardWait(),
    output: GuardOutput = .live
) -> GuardCLIResult {
    switch parseGuardArguments(arguments) {
    case .help:
        return GuardCLIResult(stdout: guardUsage, exitCode: 0)
    case .usage(let message):
        return GuardCLIResult(
            stderr: "disktriage: \(message)\n"
                + "usage: disktriage guard [--suspend] [--seconds N] [--json] [--observe]\n",
            exitCode: guardUsageExitCode
        )
    case .options(let options):
        installGuardSignalHandlers()
        resetGuardInterrupt()
        switch options.mode {
        case .dissent:
            return runDissentGuard(options: options, isRoot: isRoot, dissent: dissent, output: output)
        case .suspend:
            return runSuspendGuard(
                options: options,
                isRoot: isRoot,
                signaling: signaling,
                nodes: nodes,
                waiting: waiting,
                output: output
            )
        }
    }
}

// MARK: - Dissent mode

private func runDissentGuard(
    options: GuardOptions,
    isRoot: Bool,
    dissent: any DissentRunning,
    output: GuardOutput
) -> GuardCLIResult {
    let protection: GuardProtection = isRoot
        ? .active
        : .notActive(options.observe ? "not root; observation only" : "not root")

    output.line(.err, "mode=dissent \(protection.text)")
    output.line(
        .err,
        "limit: a dissent stops the mount but not a driver's probe reads (P0 row 5); "
            + "start guard before connecting the disk."
    )

    // An unbounded guard without root has nothing to offer: it cannot dissent,
    // so it would just idle while claiming nothing. Refuse before any session
    // is opened.
    guard isRoot || options.observe || options.seconds != nil else {
        output.line(
            .err,
            "disktriage: protection is NOT ACTIVE (not root) and no --seconds bound was "
                + "given; refusing to idle unprotected."
        )
        output.line(.err, "run it as root: \(sudoCommand(for: options))")
        return GuardCLIResult(exitCode: 30)
    }

    output.line(.err, "disktriage: guarding mount approvals for \(durationText(options.seconds))")

    let tally = GuardTally()
    let outcome = dissent.run(seconds: options.seconds) { event in
        switch event {
        case .decision(let record):
            tally.record(record)
            if options.json {
                output.line(.out, jsonDecision(record))
            } else {
                output.line(.err, ttyDecision(record))
            }
        case .appeared(let bsd, let description):
            if !options.json {
                output.line(.err, "appeared bsd=\(bsd) \(descriptionSummary(description))")
            }
        case .changed(let bsd, let keys, let description):
            if !options.json {
                output.line(
                    .err,
                    "changed bsd=\(bsd) keys=[\(keys.joined(separator: ","))] "
                        + descriptionSummary(description)
                )
            }
        }
    }

    if case .failed(let reason) = outcome {
        output.line(.err, "disktriage: \(reason)")
        return GuardCLIResult(exitCode: 30)
    }

    if options.json {
        let reason: String?
        if case .notActive(let text) = protection { reason = text } else { reason = nil }
        output.line(
            .out,
            jsonSummary(
                mode: .dissent,
                protection: protection,
                reason: reason,
                tally: tally,
                seconds: options.seconds,
                extra: ["interrupted": outcome == .interrupted]
            )
        )
    } else {
        output.line(
            .err,
            "disktriage: stopped decisions=\(tally.decisions) dissents=\(tally.dissents)"
        )
    }

    guard isRoot || options.observe else {
        output.line(
            .err,
            "disktriage: protection was NOT ACTIVE (not root); run it as root: \(sudoCommand(for: options))"
        )
        return GuardCLIResult(exitCode: 30)
    }
    return GuardCLIResult(exitCode: 0)
}

// MARK: - Suspend mode

private func runSuspendGuard(
    options: GuardOptions,
    isRoot: Bool,
    signaling: any ProcessSignaling,
    nodes: any RawDiskNodeProviding,
    waiting: any GuardWaiting,
    output: GuardOutput
) -> GuardCLIResult {
    let before = GuardProtection.notActive(
        isRoot ? "diskarbitrationd not suspended yet" : "not root"
    )
    output.line(.err, "mode=suspend \(before.text)")
    output.line(
        .err,
        "start before connecting the disk: this guard stops both the mount and the "
            + "driver's probe reads (P0 phase C)."
    )

    guard isRoot else {
        output.line(
            .err,
            "disktriage: guard --suspend needs root: SIGSTOP of diskarbitrationd is privileged, "
                + "so protection is NOT ACTIVE; refusing to claim it."
        )
        output.line(.err, "run it as root: \(sudoCommand(for: options))")
        return GuardCLIResult(exitCode: 30)
    }

    // Capture the node list while nothing is attached, before the daemon is
    // stopped: teardown compares this with the list at the end.
    let nodesAtStart = nodes.rawDiskNodes()
    let outcome = suspendDiskArbitrationDaemon(signaling)
    guard case .suspended(let pid, let state) = outcome else {
        let pidText: String
        let stateText: String
        if case .notSuspended(let reportedPid, let reportedState) = outcome {
            pidText = reportedPid.map(String.init) ?? "unknown"
            stateText = reportedState ?? "unknown"
        } else {
            pidText = "unknown"
            stateText = "unknown"
        }
        output.line(
            .err,
            "disktriage: refusing: diskarbitrationd (pid \(pidText)) is not in state T "
                + "(state=\(stateText)); it is NOT suspended. Do NOT connect the disk."
        )
        output.line(.err, "protection: NOT ACTIVE (the suspend did not take)")
        return GuardCLIResult(exitCode: 30)
    }

    let protection = GuardProtection.active
    output.line(
        .err,
        "mode=suspend protection: ACTIVE (diskarbitrationd pid \(pid) is stopped, state=\(state))"
    )
    output.line(
        .err,
        "warning: while diskarbitrationd is suspended, diskutil, Finder disk handling and "
            + "mounts hang system-wide; collect with ioreg only."
    )
    output.line(.err, "disktriage: to resume by hand at any time: \(manualResumeCommand(pid: pid))")

    let interrupted = waiting.wait(seconds: options.seconds)
    if interrupted {
        output.line(.err, "disktriage: interrupted; running teardown")
    }

    let nodesNow = nodes.rawDiskNodes()
    switch teardownDecision(nodesAtStart: nodesAtStart, nodesNow: nodesNow) {
    case .hold(let newNodes):
        output.line(
            .err,
            "disktriage: a new raw disk node is still present (\(newNodes.joined(separator: ","))); "
                + "diskarbitrationd stays SUSPENDED. unplug the disk, then run: "
                + manualResumeCommand(pid: pid)
        )
        if options.json {
            output.line(
                .out,
                jsonSummary(
                    mode: .suspend,
                    protection: protection,
                    reason: nil,
                    tally: GuardTally(),
                    seconds: options.seconds,
                    extra: [
                        "diskarbitrationd_pid": pid,
                        "teardown": "held",
                        "resumed": false,
                        "new_nodes": newNodes,
                        "interrupted": interrupted,
                    ]
                )
            )
        } else {
            output.line(.err, "disktriage: stopped; diskarbitrationd is still suspended")
        }
        return GuardCLIResult(exitCode: 0)

    case .resume:
        let resumed = resumeDiskArbitrationDaemon(signaling, pid: pid)
        guard resumed else {
            output.line(
                .err,
                "disktriage: could not resume diskarbitrationd; it is still suspended. "
                    + "unplug the disk, then run: \(manualResumeCommand(pid: pid))"
            )
            return GuardCLIResult(exitCode: 30)
        }
        let state = signaling.state(of: pid) ?? "?"
        output.line(.err, "disktriage: diskarbitrationd resumed (pid \(pid), state=\(state))")
        if options.json {
            output.line(
                .out,
                jsonSummary(
                    mode: .suspend,
                    protection: protection,
                    reason: nil,
                    tally: GuardTally(),
                    seconds: options.seconds,
                    extra: [
                        "diskarbitrationd_pid": pid,
                        "teardown": "resumed",
                        "resumed": true,
                        "new_nodes": [String](),
                        "interrupted": interrupted,
                    ]
                )
            )
        }
        return GuardCLIResult(exitCode: 0)
    }
}

// MARK: - Lines

/// The exact command the operator runs when protection is refused or the
/// daemon must be resumed by hand.
public func sudoCommand(for options: GuardOptions) -> String {
    var parts = ["sudo", "disktriage", "guard"]
    if options.mode == .suspend { parts.append("--suspend") }
    if let seconds = options.seconds {
        parts.append("--seconds")
        parts.append(secondsText(seconds))
    }
    if options.json { parts.append("--json") }
    return parts.joined(separator: " ")
}

private func durationText(_ seconds: Double?) -> String {
    guard let seconds else { return "until interrupted (Ctrl-C stops cleanly)" }
    return "\(secondsText(seconds))s"
}

func secondsText(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

public func descriptionSummary(_ description: DiskDescription) -> String {
    let proto = description.protocolName ?? "?"
    let internalFlag = description.isInternal.map { "\($0)" } ?? "?"
    return "protocol=\(proto) internal=\(internalFlag) fs=\(description.volumeKind ?? "?")"
}

public func ttyDecision(_ record: GuardDecisionRecord) -> String {
    "decision bsd=\(record.bsd) \(descriptionSummary(record.description)) "
        + "verdict=\(record.verdict.rawValue)"
}

func jsonDecision(_ record: GuardDecisionRecord) -> String {
    var object: [String: Any] = [
        "event": "decision",
        "bsd": record.bsd,
        "verdict": record.verdict.rawValue,
    ]
    object["protocol"] = record.description.protocolName.map { $0 as Any } ?? NSNull()
    object["internal"] = record.description.isInternal.map { $0 as Any } ?? NSNull()
    object["fs"] = record.description.volumeKind.map { $0 as Any } ?? NSNull()
    return jsonLine(object)
}

func jsonSummary(
    mode: GuardMode,
    protection: GuardProtection,
    reason: String?,
    tally: GuardTally,
    seconds: Double?,
    extra: [String: Any]
) -> String {
    var object: [String: Any] = [
        "event": "summary",
        "mode": mode.rawValue,
        "protection": protection.isActive ? "active" : "not_active",
        "reason": reason.map { $0 as Any } ?? NSNull(),
        "decisions": tally.decisions,
        "dissents": tally.dissents,
        "seconds": seconds.map { Int($0) } ?? NSNull(),
    ]
    for (key, value) in extra { object[key] = value }
    return jsonLine(object)
}

private func jsonLine(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

/// Mutable counters for the synchronous run-loop callback. The runtime calls
/// events on one thread; the lock is here so the @Sendable closure is honest.
final class GuardTally: @unchecked Sendable {
    private let lock = NSLock()
    private var decisionCount = 0
    private var dissentCount = 0

    var decisions: Int {
        lock.lock(); defer { lock.unlock() }
        return decisionCount
    }

    var dissents: Int {
        lock.lock(); defer { lock.unlock() }
        return dissentCount
    }

    func record(_ record: GuardDecisionRecord) {
        lock.lock(); defer { lock.unlock() }
        decisionCount += 1
        if record.verdict == .dissent { dissentCount += 1 }
    }
}

// MARK: - Help

let guardUsage = "usage: disktriage guard [--suspend] [--seconds N] [--json] [--observe]\n"
    + "\n"
    + "Holds DiskArbitration mounts for external physical disks. Start it before\n"
    + "connecting the disk (diskdoctor.md section 8).\n"
    + "\n"
    + "  --suspend     SIGSTOP diskarbitrationd for the session: stops the mount\n"
    + "                and the driver's probe reads, but diskutil, Finder disk\n"
    + "                handling and mounts hang system-wide. Needs root.\n"
    + "  --seconds N   stop after N seconds (default: until interrupted)\n"
    + "  --json        one JSON object per decision, then a final summary, on stdout\n"
    + "  --observe     observation only: run the callback, claim no protection and\n"
    + "                exit 0 without root (needs --seconds)\n"
    + "\n"
    + "Without root the dissent is not honoured: guard prints protection: NOT\n"
    + "ACTIVE, still observes with --seconds N, and exits 30 because protection was\n"
    + "requested. Run it as root: sudo disktriage guard --seconds 120\n"
