import Foundation
import DiskTriageCore
import DiskTriageCollectors

/// What the mount guard check observed (diskdoctor.md §8).
public enum GuardState: Equatable, Sendable {
    /// `diskarbitrationd` is stopped (ps state contains `T`): neither probe nor
    /// mount can happen.
    case daemonStopped
    /// A `disktriage guard` process is running (pgrep).
    case guardRunning
    case none
    /// `ps`/`pgrep` failed: unknown is not a pass.
    case unknown(String)
}

/// The machine facts the image command needs before it may read a device. A
/// test injects a scripted implementation; the live one is below.
public protocol ImagingEnvironmentProbing: Sendable {
    func isRoot() -> Bool
    func fdaStatus() -> FDAStatus
    func guardState() -> GuardState
    func ddrescueAvailable() -> Bool
    func terminal() -> TerminalIdentity
    func deviceExists(_ path: String) -> Bool
}

/// One reason the image command refuses to start. `exitCode` is the CLI code:
/// 2 for a missing flag, 30 for a precondition/tool error (never a verdict
/// code).
public struct ImagingBlocker: Equatable, Sendable {
    public let id: String
    public let message: String
    public let exitCode: Int32

    public init(id: String, message: String, exitCode: Int32) {
        self.id = id
        self.message = message
        self.exitCode = exitCode
    }
}

/// The pure precondition rules. Every refusal happens before a launcher is
/// constructed, and before the sidecar or the first read.
public struct ImagingPreconditionFacts: Sendable {
    public let isRoot: Bool
    public let fda: FDAStatus
    public let guardState: GuardState
    public let guardCheckDisabled: Bool
    public let ddrescueAvailable: Bool
    public let acceptRisk: Bool
    public let triageAttempted: Bool
    public let confirmationInstruction: String?
    public let destinationChecks: [DestinationCheck]
    public let terminal: TerminalIdentity

    public init(
        isRoot: Bool,
        fda: FDAStatus,
        guardState: GuardState,
        guardCheckDisabled: Bool,
        ddrescueAvailable: Bool,
        acceptRisk: Bool,
        triageAttempted: Bool,
        confirmationInstruction: String?,
        destinationChecks: [DestinationCheck],
        terminal: TerminalIdentity
    ) {
        self.isRoot = isRoot
        self.fda = fda
        self.guardState = guardState
        self.guardCheckDisabled = guardCheckDisabled
        self.ddrescueAvailable = ddrescueAvailable
        self.acceptRisk = acceptRisk
        self.triageAttempted = triageAttempted
        self.confirmationInstruction = confirmationInstruction
        self.destinationChecks = destinationChecks
        self.terminal = terminal
    }
}

public enum ImagingPreconditions {
    /// The consent flag is checked on its own first, so a test (or a user) that
    /// forgot it never touches a device probe to find that out.
    public static func consentBlocker(acceptRisk: Bool) -> ImagingBlocker? {
        guard !acceptRisk else { return nil }
        return ImagingBlocker(
            id: "accept-risk",
            message: "refusing to read a failing drive without --accept-risk: "
                + "reading it can finish the drive off (diskdoctor.md §12).",
            exitCode: 2
        )
    }

    public static func blockers(_ facts: ImagingPreconditionFacts) -> [ImagingBlocker] {
        var blockers: [ImagingBlocker] = []
        if let consent = consentBlocker(acceptRisk: facts.acceptRisk) {
            blockers.append(consent)
        }

        if !facts.isRoot {
            blockers.append(ImagingBlocker(
                id: "root",
                message: "imaging a raw device needs root; run the same command with sudo",
                exitCode: 30
            ))
        }

        if facts.fda.state == .denied || facts.fda.state == .unknown {
            let message = FDAGuidance.degradedImagingMessage(
                state: facts.fda.state,
                terminal: facts.terminal.name
            )
            blockers.append(ImagingBlocker(
                id: "fda",
                message: message.isEmpty
                    ? "Full Disk Access is \(facts.fda.state.rawValue); imaging is blocked."
                    : message,
                exitCode: 30
            ))
        } else if facts.fda.needsSudo && !facts.isRoot {
            blockers.append(ImagingBlocker(
                id: "fda-sudo",
                message: "Full Disk Access looks granted (EACCES): run with sudo",
                exitCode: 30
            ))
        }

        if !facts.guardCheckDisabled {
            switch facts.guardState {
            case .daemonStopped, .guardRunning:
                break
            case .none:
                blockers.append(ImagingBlocker(
                    id: "guard",
                    message: "no mount guard is in effect: diskarbitrationd is running and "
                        + "no 'disktriage guard' process was found. Start the guard before "
                        + "connecting the disk, or stop diskarbitrationd "
                        + "(sudo kill -STOP $(pgrep -x diskarbitrationd)). "
                        + "Pass --no-guard-check to proceed anyway; a probe read may already "
                        + "have happened.",
                    exitCode: 30
                ))
            case .unknown(let reason):
                blockers.append(ImagingBlocker(
                    id: "guard",
                    message: "the mount guard state could not be determined (\(reason)); "
                        + "pass --no-guard-check to proceed anyway; a probe read may already "
                        + "have happened.",
                    exitCode: 30
                ))
            }
        }

        if !facts.ddrescueAvailable {
            blockers.append(ImagingBlocker(
                id: "ddrescue",
                message: "ddrescue was not found; install it (brew install ddrescue) before imaging",
                exitCode: 30
            ))
        }

        if !facts.triageAttempted {
            blockers.append(ImagingBlocker(
                id: "triage",
                message: "the triage attempt failed; rerun triage or pass --override",
                exitCode: 30
            ))
        }

        if let instruction = facts.confirmationInstruction {
            blockers.append(ImagingBlocker(id: "confirmation", message: instruction, exitCode: 30))
        }

        for check in facts.destinationChecks where check.outcome != .pass {
            blockers.append(ImagingBlocker(
                id: "destination",
                message: "\(check.name): \(check.detail)",
                exitCode: 30
            ))
        }

        return blockers
    }
}

// MARK: - Live environment

/// The live implementation. It only probes when a method is called, and the
/// raw-device read is the same 4096-byte internal-disk probe as `check`
/// (never the suspect disk, diskdoctor.md §7).
public struct LiveImagingEnvironment: ImagingEnvironmentProbing {
    private let probes: LiveCheckProbes

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.probes = LiveCheckProbes(executor: executor)
    }

    public func isRoot() -> Bool {
        probes.runningAsRoot()
    }

    public func fdaStatus() -> FDAStatus {
        let first = probes.probeRawDevice()
        let second = first.isSuccessfulRead ? probes.probeRawDevice() : nil
        return FDAStateMachine.evaluate(first: first, second: second)
    }

    public func guardState() -> GuardState {
        guard let processList = Self.run("/bin/ps", ["-axo", "stat=,comm="]) else {
            return .unknown("ps could not be run")
        }

        for line in processList.split(whereSeparator: \.isNewline) {
            guard line.contains("diskarbitrationd") else { continue }
            let stat = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if stat.contains("T") {
                return .daemonStopped
            }
        }

        if let guardPIDs = Self.run("/usr/bin/pgrep", ["-f", "disktriage guard"]),
           !guardPIDs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .guardRunning
        }

        return .none
    }

    public func ddrescueAvailable() -> Bool {
        let candidates = [
            "/opt/homebrew/bin/ddrescue",
            "/usr/local/bin/ddrescue",
            "/usr/bin/ddrescue",
        ]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/ddrescue"
            if FileManager.default.isExecutableFile(atPath: candidate) { return true }
        }
        return false
    }

    public func terminal() -> TerminalIdentity {
        probes.terminal()
    }

    public func deviceExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
