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
    /// The requested byte limit, before it is resolved against the device; a
    /// value at or above the device is the full device (REQ-0101).
    let limitBytes: Int64?
    /// The whole-GiB form for the printed resume command, `nil` when the limit
    /// came from the byte seam rather than `--limit`.
    let limitGiB: Int64?
}

/// The final summary: stdout and `--json` are two renderings of this value.
struct ImagingSummary {
    let status: String
    let exitCode: Int32
    let image: String
    let mapfile: String
    let sidecar: String
    let rescuedBytes: Int64?
    /// `*` plus `/`: read errors seen, not yet trimmed or scraped.
    let failedBytes: Int64?
    let failedExtents: Int?
    /// `-`: confirmed bad.
    let badBytes: Int64?
    let badExtents: Int?
    let remainingBytes: Int64?
    let remainingExtents: Int?
    let elapsedSeconds: Double
    let passReached: Int
    let stopped: PassStopReason
    /// The pass's exit code; shown only when ddrescue stopped by itself.
    let stopExitCode: Int32?
    /// The `-T` value from the stopping pass's argv, when it has one.
    let stopTimeout: String?
    let resumeCommand: String?
    let stop: Pass2Stop?
    /// The effective partial limit, `nil` for a full image (REQ-0106).
    let partialLimitBytes: Int64?
    let deviceBytes: Int64?

    init(
        status: String,
        exitCode: Int32,
        image: String,
        mapfile: String,
        sidecar: String,
        rescuedBytes: Int64?,
        failedBytes: Int64?,
        failedExtents: Int?,
        badBytes: Int64?,
        badExtents: Int?,
        remainingBytes: Int64?,
        remainingExtents: Int?,
        elapsedSeconds: Double,
        passReached: Int,
        stopped: PassStopReason,
        stopExitCode: Int32? = nil,
        stopTimeout: String? = nil,
        resumeCommand: String?,
        stop: Pass2Stop?,
        partialLimitBytes: Int64?,
        deviceBytes: Int64?
    ) {
        self.status = status
        self.exitCode = exitCode
        self.image = image
        self.mapfile = mapfile
        self.sidecar = sidecar
        self.rescuedBytes = rescuedBytes
        self.failedBytes = failedBytes
        self.failedExtents = failedExtents
        self.badBytes = badBytes
        self.badExtents = badExtents
        self.remainingBytes = remainingBytes
        self.remainingExtents = remainingExtents
        self.elapsedSeconds = elapsedSeconds
        self.passReached = passReached
        self.stopped = stopped
        self.stopExitCode = stopExitCode
        self.stopTimeout = stopTimeout
        self.resumeCommand = resumeCommand
        self.stop = stop
        self.partialLimitBytes = partialLimitBytes
        self.deviceBytes = deviceBytes
    }

    var isComplete: Bool { exitCode == 0 }
    var isPartial: Bool { partialLimitBytes != nil }

    /// `complete` is only honest for a full image. A partial run that finished
    /// says so, and never claims the whole device (REQ-0106).
    var stoppedDisplay: String {
        if status == "complete" || status.hasPrefix("partial image complete") {
            return status
        }
        if stopped == .stoppedOnItsOwn, let code = stopExitCode {
            return "ddrescue stopped on its own, exit \(code)"
        }
        return stopped.rawValue
    }

    /// The sentence that turns an exit code into a reason. `-T 90` is the
    /// measured cause on the failing MiNaH drive: ddrescue stopped itself after
    /// 90 s without a successful read while a bad region stalled reads.
    var stopDetail: String? {
        guard stopped == .stoppedOnItsOwn, let code = stopExitCode else { return nil }
        var parts = ["exit \(code): \(DdrescueExitStatus.describe(code))"]
        if let timeout = stopTimeout {
            parts.append(
                "with -T \(timeout) ddrescue stops after \(timeout) s without a successful read; "
                    + "the drive may be stalling on a bad region; the image is resumable"
            )
        }
        return parts.joined(separator: "; ")
    }
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
    let partialLimitBytes = recordedLimitBytes(
        deviceBytes: plan.source.sizeBytes,
        limitBytes: plan.limitBytes
    )
    let imageBytes = effectiveImageBytes(
        deviceBytes: plan.source.sizeBytes,
        limitBytes: plan.limitBytes
    )
    let sidecarPath = plan.image + ".disktriage.json"
    let sidecar = ImageSidecar(
        schema: "disktriage.image/1",
        device: ImageSidecarDevice(
            model: plan.source.model,
            serialSHA256: plan.source.serial.map(imageSerialHash),
            sizeBytes: plan.source.sizeBytes ?? 0
        ),
        createdAt: iso8601String(startedAt),
        command: plan.passes.map(\.line),
        limitBytes: partialLimitBytes
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
            // The stop rule's 0.01% threshold and remaining-time projection are
            // about the image being written, so a partial run uses the limit
            // as its "device" size (REQ-0107).
            deviceSize: imageBytes ?? plan.source.sizeBytes ?? 0,
            mapfileLimitBytes: partialLimitBytes,
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
    progress.append("disktriage: pass 1 \(passOutcome(result))")

    if result.reason == .complete {
        passReached = 2
        progress.append("disktriage: pass 2 (\(plan.passes[1].line)) started")
        result = supervisor.run(plan.passes[1], applyStopRule: true)
        progress.append(contentsOf: progressLog.drain())
        progress.append("disktriage: pass 2 \(passOutcome(result))")
    }

    let status: String
    if result.reason == .launchFailed {
        status = "tool-error"
    } else if result.reason == .complete {
        status = partialLimitBytes.map {
            "partial image complete (first \(partialExtentLabel($0)))"
        } ?? "complete"
    } else {
        status = "incomplete"
    }

    let summary = ImagingSummary(
        status: status,
        exitCode: result.reason == .launchFailed ? 30
            : result.reason == .complete ? 0 : 1,
        image: plan.image,
        mapfile: plan.mapfile,
        sidecar: sidecarPath,
        rescuedBytes: result.snapshot?.rescuedBytes,
        failedBytes: result.snapshot?.failedBytes,
        failedExtents: result.snapshot?.failedExtents.count,
        badBytes: result.snapshot?.badBytes,
        badExtents: result.snapshot?.badExtents.count,
        remainingBytes: result.snapshot?.remainingBytes,
        remainingExtents: result.snapshot?.remainingExtents.count,
        elapsedSeconds: now().timeIntervalSince(startedAt),
        passReached: passReached,
        stopped: result.reason,
        stopExitCode: result.reason == .stoppedOnItsOwn ? result.exitCode : nil,
        stopTimeout: result.reason == .stoppedOnItsOwn
            ? ddrescueTimeoutArgument(plan.passes[passReached - 1].argv)
            : nil,
        resumeCommand: result.reason == .complete ? nil : resumeCommand(plan),
        stop: result.stop,
        partialLimitBytes: partialLimitBytes,
        deviceBytes: plan.source.sizeBytes
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
        let key = "\(progress.pass)-\(progress.rescuedBytes)-\(progress.failedBytes)-"
            + "\(progress.badBytes)-\(progress.remainingBytes)"
        guard key != lastKey else { return }
        lastKey = key
        lines.append(String(
            format: "disktriage: pass %d: %.1f%% rescued (%@), %@ bad, %@ failed (%d extents), %@ remaining",
            progress.pass,
            progress.percent,
            bytes(progress.rescuedBytes),
            bytes(progress.badBytes),
            bytes(progress.failedBytes),
            progress.failedExtents,
            bytes(progress.remainingBytes)
        ))
    }

    func drain() -> [String] {
        defer { lines.removeAll() }
        return lines
    }
}

// MARK: - Rendering

/// The per-pass stderr line. A pass ddrescue stopped by itself carries its
/// exit code; anything else keeps the reason's own wording.
private func passOutcome(_ result: PassResult) -> String {
    if result.reason == .stoppedOnItsOwn, let code = result.exitCode {
        return "ddrescue stopped on its own, exit \(code)"
    }
    return result.reason.rawValue
}

/// The `-T` value in a pass argv, e.g. `90` for `... -T 90 ...`.
func ddrescueTimeoutArgument(_ argv: [String]) -> String? {
    guard let index = argv.firstIndex(of: "-T"), index + 1 < argv.count else { return nil }
    return argv[index + 1]
}

func renderImagingTTY(_ summary: ImagingSummary) -> String {
    var lines: [String] = []
    lines.append(pad("IMAGE", 10) + summary.image)
    lines.append(pad("MAPFILE", 10) + summary.mapfile)
    lines.append(pad("SIDECAR", 10) + summary.sidecar)
    lines.append(pad("RESCUED", 10) + optionalBytes(summary.rescuedBytes))
    lines.append(pad("FAILED", 10)
        + "\(optionalBytes(summary.failedBytes)) in \(optionalCount(summary.failedExtents)) extents "
        + "(read errors seen; not yet trimmed or scraped)")
    lines.append(pad("BAD", 10)
        + "\(optionalBytes(summary.badBytes)) in \(optionalCount(summary.badExtents)) extents (confirmed)")
    let remaining = summary.remainingBytes.map { bytes($0) } ?? "unknown"
    let extents = summary.remainingExtents.map(String.init) ?? "unknown"
    lines.append(pad("REMAINING", 10) + "\(remaining) in \(extents) extents")
    lines.append(pad("ELAPSED", 10) + String(format: "%.1f s", summary.elapsedSeconds))
    lines.append(pad("PASS", 10) + "reached \(summary.passReached)")
    if let limit = summary.partialLimitBytes {
        lines.append(pad("LIMIT", 10)
            + "first \(gib(limit)) of \(gib(summary.deviceBytes)) — PARTIAL image")
    }
    lines.append(pad("STOPPED", 10) + summary.stoppedDisplay)
    if let detail = summary.stopDetail {
        lines.append(pad("NOTE", 10) + detail)
    }
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

func renderImagingJSON(_ summary: ImagingSummary) -> String {
    var object: [String: Any] = [
        "status": summary.status,
        "exit_code": Int(summary.exitCode),
        "image": summary.image,
        "mapfile": summary.mapfile,
        "sidecar": summary.sidecar,
        "elapsed_seconds": summary.elapsedSeconds,
        "pass_reached": summary.passReached,
        "stopped": summary.stoppedDisplay,
        "partial": summary.isPartial,
        "zero_filled": "unreadable regions are zero-filled in the image; "
            + "a volume-level damage report is the next step",
    ]
    if let rescued = summary.rescuedBytes { object["rescued_bytes"] = rescued }
    if let failed = summary.failedBytes { object["failed_bytes"] = failed }
    if let extents = summary.failedExtents { object["failed_extents"] = extents }
    if let bad = summary.badBytes { object["bad_bytes"] = bad }
    if let extents = summary.badExtents { object["bad_extents"] = extents }
    if let remaining = summary.remainingBytes { object["remaining_bytes"] = remaining }
    if let extents = summary.remainingExtents { object["remaining_extents"] = extents }
    if let code = summary.stopExitCode { object["stop_exit_code"] = Int(code) }
    if let detail = summary.stopDetail { object["stop_detail"] = detail }
    if let limit = summary.partialLimitBytes { object["limit_bytes"] = limit }
    if let device = summary.deviceBytes { object["device_bytes"] = device }
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
    if let limit = plan.limitGiB {
        parts += ["--limit", String(limit)]
    }
    if plan.override { parts.append("--override") }
    if plan.noGuardCheck { parts.append("--no-guard-check") }
    return parts.joined(separator: " ")
}

// MARK: - Formatting

private func optionalBytes(_ value: Int64?) -> String {
    value.map(bytes) ?? "unknown"
}

private func optionalCount(_ value: Int?) -> String {
    value.map(String.init) ?? "unknown"
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
