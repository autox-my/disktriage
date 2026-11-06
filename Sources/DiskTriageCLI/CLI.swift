import Foundation
import DiskTriageCore

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
/// process. Reading a file is injected; `DiskTriageCore` stays pure.
///
/// `now` is part of the seam for the live collectors (P2); recorded SignalSets
/// carry their own `collected_at`, so it is not consulted yet.
public func run(
    arguments: [String],
    readFile: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
    now: () -> Date = Date.init
) -> CLIResult {
    _ = now
    guard let command = arguments.first else {
        return rootHelp()
    }

    let rest = Array(arguments.dropFirst())
    switch command {
    case "--help", "-h", "help":
        return rootHelp()
    case "triage":
        return triage(rest, readFile: readFile)
    case "image", "inspect", "copy", "check", "guard", "list":
        return planned(command, rest)
    default:
        return usageError("unknown command '\(command)'")
    }
}

// MARK: - triage

private func triage(
    _ arguments: [String],
    readFile: (String) throws -> Data
) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(triageUsage)
    }

    var from: String?
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
        case "--json":
            asJSON = true
            index += 1
        case "--local":
            local = true
            index += 1
        default:
            return usageError("unknown option '\(arguments[index])'")
        }
    }

    guard let from else {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: live collection arrives with the collectors (planned P2); "
                + "nothing was read. Use --from <signalset.json> for a recorded set.\n",
            exitCode: 30
        )
    }

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

    let signals: SignalSet
    do {
        signals = try JSONDecoder.disktriage().decode(SignalSet.self, from: data)
    } catch {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: malformed SignalSet JSON in \(from): \(error)\n",
            exitCode: 30
        )
    }

    // A recorded set has no live device, so the suggested image destination is
    // derived from its name; the Appendix's transcript was rendered that way.
    let destination = "/Volumes/Scratch/\(fileStem(from)).img"
    let verdict = classify(signals, context: TriageContext(imageDestination: destination))
    let stdout = asJSON
        ? Renderer.json(verdict)
        : Renderer.tty(
            signals,
            verdict,
            timeZone: local ? TimeZone.current : TimeZone(secondsFromGMT: 0)!
        )
    let device = signals.device?.bsd ?? "unknown device"
    let stderr = "disktriage: reading \(from)\n"
        + "disktriage: classified \(device) as exit \(verdict.code.rawValue)\n"

    return CLIResult(stdout: stdout, stderr: stderr, exitCode: Int32(verdict.code.rawValue))
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
            + "  triage   classify a recorded SignalSet (--from <signalset.json>)\n"
            + "  image    image a device to a file           (planned P2)\n"
            + "  inspect  inspect an image read-only         (planned P2)\n"
            + "  copy     copy an image with a manifest      (planned P3)\n"
            + "  check    permissions and tooling self-test  (planned P2)\n"
            + "  guard    hold mounts for attached disks     (planned P2)\n"
            + "  list     list devices with a health line    (planned P2)\n"
            + "\n"
            + "Run 'disktriage <command> --help' for options.\n"
    )
}

private let triageUsage = "usage: disktriage triage --from <signalset.json> [--json] [--local]\n"
    + "\n"
    + "Classifies a recorded SignalSet. Live collection arrives with the collectors\n"
    + "(planned P2); without --from there is nothing to read.\n"
    + "\n"
    + "  --from <file>  recorded SignalSet JSON (the only signal source for now)\n"
    + "  --json         print the verdict as JSON instead of the tty transcript\n"
    + "  --local        render log timestamps in the local zone (default UTC)\n"

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
