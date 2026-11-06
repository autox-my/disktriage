import Foundation
import DiskTriageCore
import DiskTriageCollectors

/// Everything `disktriage image --no-dry-run` needs after the dry-run plan has
/// been built. Values, not lookups: the orchestration below is driven by tests
/// through the injected environment and launcher.
struct ImagingPlan {
    let disk: String
    let rawDevice: String
    let image: String
    let mapfile: String
    let source: ImageSource
    let passes: [DdrescuePass]
    let destinationChecks: [DestinationCheck]
    let triageAttempted: Bool
    let confirmationInstruction: String?
    let asJSON: Bool
    let acceptRisk: Bool
    let noGuardCheck: Bool
    let override: Bool
    let confirmSerial: String?
    let confirmSize: Int64?
}

/// The final summary: stdout and `--json` are two renderings of this value.
struct ImagingSummary {
    let status: String
    let exitCode: Int32
    let image: String
    let mapfile: String
    let sidecar: String
    let rescuedBytes: Int64?
    let badBytes: Int64?
    let remainingBytes: Int64?
    let remainingExtents: Int?
    let elapsedSeconds: Double
    let passReached: Int
    let stopped: PassStopReason
    let resumeCommand: String?
    let stop: Pass2Stop?

    var isComplete: Bool { exitCode == 0 }
}

/// Runs the preconditions, writes the sidecar, supervises both passes, and
/// renders the summary. Nothing here touches a device directly.
func runImaging(
    _ plan: ImagingPlan,
    dependencies: ImagingDependencies?,
    executor: any CommandExecuting,
    writeFile: (String, Data) throws -> Void,
    now: @escaping () -> Date
) -> CLIResult {
    // Consent first: a forgotten --accept-risk must not probe a device to find
    // out. This is also what keeps a test that omits the flag off the machine.
    if let consent = ImagingPreconditions.consentBlocker(acceptRisk: plan.acceptRisk) {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: \(consent.message)\n",
            exitCode: consent.exitCode
        )
    }

    let dependencies = dependencies ?? .live(executor: executor)
    let environment = dependencies.environment

    let facts = ImagingPreconditionFacts(
        isRoot: environment.isRoot(),
        fda: environment.fdaStatus(),
        guardState: environment.guardState(),
        guardCheckDisabled: plan.noGuardCheck,
        ddrescueAvailable: environment.ddrescueAvailable(),
        acceptRisk: plan.acceptRisk,
        triageAttempted: plan.triageAttempted,
        confirmationInstruction: plan.confirmationInstruction,
        destinationChecks: plan.destinationChecks,
        terminal: environment.terminal()
    )
    let blockers = ImagingPreconditions.blockers(facts)
    if !blockers.isEmpty {
        let messages = blockers.map { "disktriage: \($0.message)" }
        let code = blockers.contains { $0.exitCode == 30 } ? Int32(30) : blockers[0].exitCode
        return CLIResult(stdout: "", stderr: messages.joined(separator: "\n") + "\n", exitCode: code)
    }

    var progress: [String] = []
    if plan.noGuardCheck {
        progress.append(
            "disktriage: warning: --no-guard-check: a mount probe read may already have happened"
        )
    }

    let startedAt = now()
    let sidecarPath = plan.image + ".disktriage.json"
    let sidecar = ImageSidecar(
        schema: "disktriage.image/1",
        device: ImageSidecarDevice(
            model: plan.source.model,
            serialSHA256: plan.source.serial.map(imageSerialHash),
            sizeBytes: plan.source.sizeBytes ?? 0
        ),
        createdAt: iso8601String(startedAt),
        command: plan.passes.map(\.line)
    )
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeFile(sidecarPath, try encoder.encode(sidecar))
    } catch {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: cannot write the sidecar \(sidecarPath): "
                + "\(error.localizedDescription); refusing to read before it exists\n",
            exitCode: 30
        )
    }

    let progressLog = ProgressLog()
    let supervisor = DdrescueSupervisor(
        launcher: dependencies.launcher,
        configuration: .init(
            mapfilePath: plan.mapfile,
            devicePath: plan.rawDevice,
            deviceSize: plan.source.sizeBytes ?? 0,
            pollInterval: dependencies.pollInterval,
            signalGrace: dependencies.signalGrace,
            readMapfile: dependencies.readMapfile,
            deviceExists: { environment.deviceExists($0) },
            now: now,
            sleep: dependencies.sleep,
            interruptRequested: dependencies.interruptRequested,
            progress: { progressLog.record($0) }
        )
    )

    guard plan.passes.count == 2 else {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: the two-pass command could not be built\n",
            exitCode: 30
        )
    }

    progress.append("disktriage: pass 1 (\(plan.passes[0].line)) started")
    var result = supervisor.run(plan.passes[0], applyStopRule: false)
    var passReached = 1
    progress.append(contentsOf: progressLog.drain())
    progress.append("disktriage: pass 1 \(result.reason.rawValue)")

    if result.reason == .complete {
        passReached = 2
        progress.append("disktriage: pass 2 (\(plan.passes[1].line)) started")
        result = supervisor.run(plan.passes[1], applyStopRule: true)
        progress.append(contentsOf: progressLog.drain())
        progress.append("disktriage: pass 2 \(result.reason.rawValue)")
    }

    let summary = ImagingSummary(
        status: result.reason == .launchFailed ? "tool-error"
            : result.reason == .complete ? "complete" : "incomplete",
        exitCode: result.reason == .launchFailed ? 30
            : result.reason == .complete ? 0 : 1,
        image: plan.image,
        mapfile: plan.mapfile,
        sidecar: sidecarPath,
        rescuedBytes: result.snapshot?.rescuedBytes,
        badBytes: result.snapshot?.badBytes,
        remainingBytes: result.snapshot?.remainingBytes,
        remainingExtents: result.snapshot?.remainingExtents.count,
        elapsedSeconds: now().timeIntervalSince(startedAt),
        passReached: passReached,
        stopped: result.reason,
        resumeCommand: result.reason == .complete ? nil : resumeCommand(plan),
        stop: result.stop
    )

    if let launchError = result.launchError {
        progress.append("disktriage: ddrescue could not be launched: \(launchError)")
    }

    let stdout = plan.asJSON ? renderImagingJSON(summary) : renderImagingTTY(summary)
    return CLIResult(
        stdout: stdout,
        stderr: progress.joined(separator: "\n") + "\n",
        exitCode: summary.exitCode
    )
}

// MARK: - Progress

/// Deduplicates mapfile samples so a long pass prints one line per change, not
/// one per poll.
final class ProgressLog {
    private var lines: [String] = []
    private var lastKey: String?

    func record(_ progress: ImagingProgress) {
        let key = "\(progress.pass)-\(progress.rescuedBytes)-\(progress.badBytes)-\(progress.remainingBytes)"
        guard key != lastKey else { return }
        lastKey = key
        lines.append(String(
            format: "disktriage: pass %d: %.1f%% rescued (%@), %@ bad, %@ remaining",
            progress.pass,
            progress.percent,
            bytes(progress.rescuedBytes),
            bytes(progress.badBytes),
            bytes(progress.remainingBytes)
        ))
    }

    func drain() -> [String] {
        defer { lines.removeAll() }
        return lines
    }
}

// MARK: - Rendering

private func renderImagingTTY(_ summary: ImagingSummary) -> String {
    var lines: [String] = []
    lines.append(pad("IMAGE", 10) + summary.image)
    lines.append(pad("MAPFILE", 10) + summary.mapfile)
    lines.append(pad("SIDECAR", 10) + summary.sidecar)
    lines.append(pad("RESCUED", 10) + optionalBytes(summary.rescuedBytes))
    lines.append(pad("BAD", 10) + optionalBytes(summary.badBytes))
    let remaining = summary.remainingBytes.map { bytes($0) } ?? "unknown"
    let extents = summary.remainingExtents.map(String.init) ?? "unknown"
    lines.append(pad("REMAINING", 10) + "\(remaining) in \(extents) extents")
    lines.append(pad("ELAPSED", 10) + String(format: "%.1f s", summary.elapsedSeconds))
    lines.append(pad("PASS", 10) + "reached \(summary.passReached)")
    lines.append(pad("STOPPED", 10) + summary.stopped.rawValue)
    if let stop = summary.stop {
        lines.append(pad("YIELD", 10)
            + "\(bytes(stop.marginalYieldBytes)) in the trailing 10 minutes; "
            + "projected \(String(format: "%.0f", stop.projectedRemainingSeconds)) s remaining")
    }
    lines.append(pad("NOTE", 10)
        + "unreadable regions are zero-filled in the image; that is not an I/O error. "
        + "A volume-level damage report (disktriage copy / inspect) is the next step.")
    if let resume = summary.resumeCommand {
        lines.append(pad("RESUME", 10) + resume)
    }
    return lines.joined(separator: "\n") + "\n"
}

private func renderImagingJSON(_ summary: ImagingSummary) -> String {
    var object: [String: Any] = [
        "status": summary.status,
        "exit_code": Int(summary.exitCode),
        "image": summary.image,
        "mapfile": summary.mapfile,
        "sidecar": summary.sidecar,
        "elapsed_seconds": summary.elapsedSeconds,
        "pass_reached": summary.passReached,
        "stopped": summary.stopped.rawValue,
        "zero_filled": "unreadable regions are zero-filled in the image; "
            + "a volume-level damage report is the next step",
    ]
    if let rescued = summary.rescuedBytes { object["rescued_bytes"] = rescued }
    if let bad = summary.badBytes { object["bad_bytes"] = bad }
    if let remaining = summary.remainingBytes { object["remaining_bytes"] = remaining }
    if let extents = summary.remainingExtents { object["remaining_extents"] = extents }
    if let resume = summary.resumeCommand { object["resume_command"] = resume }
    if let stop = summary.stop {
        object["stop_rule"] = [
            "marginal_yield_bytes": stop.marginalYieldBytes,
            "projected_remaining_seconds": stop.projectedRemainingSeconds,
            "elapsed_seconds": stop.elapsedSeconds,
        ]
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let text = String(data: data, encoding: .utf8) else {
        return "{}\n"
    }
    return text + "\n"
}

// MARK: - Resume

private func resumeCommand(_ plan: ImagingPlan) -> String {
    var parts = [
        "sudo", "disktriage", "image", plan.disk,
        "--to", plan.image,
        "--no-dry-run",
        "--accept-risk",
    ]
    if plan.mapfile != plan.image + ".mapfile" {
        parts += ["--mapfile", plan.mapfile]
    }
    if let serial = plan.confirmSerial {
        parts += ["--confirm-serial", serial]
    }
    if let size = plan.confirmSize {
        parts += ["--confirm-size", String(size)]
    }
    if plan.override { parts.append("--override") }
    if plan.noGuardCheck { parts.append("--no-guard-check") }
    return parts.joined(separator: " ")
}

// MARK: - Formatting

private func optionalBytes(_ value: Int64?) -> String {
    value.map(bytes) ?? "unknown"
}

private func bytes(_ value: Int64) -> String {
    if value >= 1_073_741_824 {
        return String(format: "%.1f GiB (%lld bytes)", Double(value) / 1_073_741_824, value)
    }
    if value >= 1_048_576 {
        return String(format: "%.1f MiB (%lld bytes)", Double(value) / 1_048_576, value)
    }
    if value >= 1_024 {
        return String(format: "%.1f KiB (%lld bytes)", Double(value) / 1_024, value)
    }
    return "\(value) bytes"
}

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}

func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
