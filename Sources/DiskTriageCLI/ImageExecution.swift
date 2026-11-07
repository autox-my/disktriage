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
    /// The stage 0..2 commands the dry run printed, recorded in the sidecar.
    let plannedStages: [PlannedStage]
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
    /// The pass-1 `ddrescue -a` threshold, `nil` when disabled. Informational
    /// in the sidecar, never part of the resume identity (REQ-0183).
    let minReadRateBytesPerSecond: Int64?
    /// Stop after stage 1; free space is not imaged (REQ-0204).
    let usedOnly: Bool
    /// Stop after stage 0 and report the allocation (REQ-0221). Never
    /// combined with `usedOnly`; the CLI refuses that as a usage error.
    let scopeReport: Bool
    /// The previous run's stage state, for a resume. `--used-only` itself is
    /// not identity; the stage state is informational (REQ-0207).
    let previousAllocation: ImageSidecarAllocation?
}

/// One stage line in the human and JSON summary.
struct ImagingStageReport: Equatable, Sendable {
    let stage: Int
    let name: String
    /// `done`, `failed`, `skipped`, `not run`, ...
    let status: String
    let detail: String?
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
    /// The pass-1 slow-zone threshold in bytes/s, `nil` when disabled
    /// (REQ-0182).
    let minReadRateBytesPerSecond: Int64?
    /// What this run asked the imager to cover (REQ-0208). Defaults to the
    /// whole device when no allocation stage was involved.
    let scope: String
    let stages: [ImagingStageReport]
    let allocation: ImageSidecarAllocation?
    /// The scope's accounting (REQ-0212); `nil` means the whole-device numbers
    /// above are the scope.
    let scopeTotalBytes: Int64?
    let scopeRescuedBytes: Int64?
    let scopeFailedBytes: Int64?
    let scopeFailedExtents: Int?
    let scopeBadBytes: Int64?
    let scopeBadExtents: Int?
    let scopeRemainingBytes: Int64?

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
        deviceBytes: Int64?,
        minReadRateBytesPerSecond: Int64? = nil,
        scope: String = "whole device",
        stages: [ImagingStageReport] = [],
        allocation: ImageSidecarAllocation? = nil,
        scopeTotalBytes: Int64? = nil,
        scopeRescuedBytes: Int64? = nil,
        scopeFailedBytes: Int64? = nil,
        scopeFailedExtents: Int? = nil,
        scopeBadBytes: Int64? = nil,
        scopeBadExtents: Int? = nil,
        scopeRemainingBytes: Int64? = nil
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
        self.minReadRateBytesPerSecond = minReadRateBytesPerSecond
        self.scope = scope
        self.stages = stages
        self.allocation = allocation
        self.scopeTotalBytes = scopeTotalBytes
        self.scopeRescuedBytes = scopeRescuedBytes
        self.scopeFailedBytes = scopeFailedBytes
        self.scopeFailedExtents = scopeFailedExtents
        self.scopeBadBytes = scopeBadBytes
        self.scopeBadExtents = scopeBadExtents
        self.scopeRemainingBytes = scopeRemainingBytes
    }

    var isComplete: Bool { exitCode == 0 }
    var isPartial: Bool { partialLimitBytes != nil }

    /// `complete` is only honest for a full image. A partial run that finished
    /// says so, and never claims the whole device (REQ-0106); a used-only run
    /// says the free space was not imaged (REQ-0208).
    var stoppedDisplay: String {
        if status == "complete" || status.hasPrefix("partial image complete")
            || status.hasPrefix("used-only image complete") {
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
    writeFile: @escaping (String, Data) throws -> Void,
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
    let imageLimit = imageBytes ?? plan.source.sizeBytes ?? 0
    let sidecarPath = plan.image + ".disktriage.json"
    let timeoutSeconds = 90

    var allocation = ImageSidecarAllocation(
        usedOnly: plan.usedOnly,
        mode: "unknown",
        stage0: "not-started",
        stage1: "not-started",
        stage2: "not-started"
    )
    /// Set by a successful `--scope-report` (or a failed one, left nil so no
    /// numbers are recorded). A later full run reads it and re-runs stage 0.
    var scopeReportRecord: ImageSidecarScopeReport?

    func persistSidecar() throws {
        let command: [String]
        if plan.scopeReport {
            // Only the reads this attempt made, not the stages it never ran.
            command = plan.plannedStages.filter { $0.stage == 0 }.flatMap(\.lines)
        } else {
            command = dependencies.allocationAware
                ? plan.plannedStages.flatMap(\.lines)
                : plan.passes.map(\.line)
        }
        let sidecar = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(
                model: plan.source.model,
                serialSHA256: plan.source.serial.map(imageSerialHash),
                sizeBytes: plan.source.sizeBytes ?? 0
            ),
            createdAt: iso8601String(startedAt),
            command: command,
            limitBytes: partialLimitBytes,
            minReadRateBytesPerSecond: plan.minReadRateBytesPerSecond,
            allocation: allocation,
            scopeReport: scopeReportRecord
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeFile(sidecarPath, try encoder.encode(sidecar))
    }

    do {
        try persistSidecar()
    } catch {
        return CLIResult(
            stdout: "",
            stderr: "disktriage: cannot write the sidecar \(sidecarPath): "
                + "\(error.localizedDescription); refusing to read before it exists\n",
            exitCode: 30
        )
    }

    func updateAllocation(
        mode: String? = nil,
        stage0: String? = nil,
        reason: String? = nil,
        geometrySource: String? = nil,
        stage1: String? = nil,
        stage2: String? = nil
    ) {
        allocation = ImageSidecarAllocation(
            usedOnly: plan.usedOnly,
            mode: mode ?? allocation.mode,
            stage0: stage0 ?? allocation.stage0,
            stage0Reason: reason ?? allocation.stage0Reason,
            geometrySource: geometrySource ?? allocation.geometrySource,
            stage1: stage1 ?? allocation.stage1,
            stage2: stage2 ?? allocation.stage2
        )
        do {
            try persistSidecar()
        } catch {
            progress.append(
                "disktriage: warning: cannot update the sidecar: \(error.localizedDescription)"
            )
        }
    }

    let progressLog = ProgressLog()

    func makeSupervisor(
        _ pass: DdrescuePass,
        scope: [ByteRange]?
    ) -> DdrescueSupervisor {
        DdrescueSupervisor(
            launcher: dependencies.launcher,
            configuration: .init(
                mapfilePath: plan.mapfile,
                devicePath: plan.rawDevice,
                // The stop rule's 0.01% threshold and remaining-time projection
                // are about the image being written, so a partial run uses the
                // limit as its "device" size (REQ-0107).
                deviceSize: imageBytes ?? plan.source.sizeBytes ?? 0,
                mapfileLimitBytes: partialLimitBytes,
                scope: scope,
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
    }

    var stageReports: [ImagingStageReport] = []
    var lastPass: DdrescuePass?
    var passReached = 0

    /// The one stage-0 read path, shared by a full imaging run and a scope
    /// report: the same domain mapfile, the same main mapfile and the same
    /// safety gates (REQ-0221, REQ-0226).
    func performStage0() -> Stage0Outcome {
        runStage0(Stage0Context(
            deviceSize: plan.source.sizeBytes ?? 0,
            imageBytes: imageLimit,
            rawDevice: plan.rawDevice,
            image: plan.image,
            mapfile: plan.mapfile,
            blockSize: plan.source.blockSize ?? 512,
            timeoutSeconds: timeoutSeconds,
            limitBytes: partialLimitBytes,
            writeFile: writeFile,
            readImage: dependencies.readImage,
            readMapfile: dependencies.readMapfile,
            run: { pass, extentScope in
                lastPass = pass
                passReached = max(passReached, 1)
                progress.append(
                    "disktriage: stage 0 (\(pass.line)) started"
                )
                let value = makeSupervisor(pass, scope: extentScope)
                    .run(pass, applyStopRule: false)
                progress.append(contentsOf: progressLog.drain())
                progress.append("disktriage: stage 0 \(passOutcome(value))")
                return value
            },
            progress: { progress.append($0) }
        ))
    }

    // `--scope-report`: stage 0 only, then the allocation, and exit 0. No
    // stage 1 or 2 argv is built or launched (REQ-0221).
    if plan.scopeReport {
        guard dependencies.allocationAware else {
            return CLIResult(
                stdout: "",
                stderr: "disktriage: --scope-report needs the allocation-aware stage 0, "
                    + "which this dependency set did not enable\n",
                exitCode: 30
            )
        }

        switch performStage0() {
        case .known(let stage0):
            updateAllocation(
                mode: "allocation-aware",
                stage0: "done",
                geometrySource: stage0.geometrySource.rawValue
            )
            let report = makeScopeReport(
                stage0: stage0,
                source: plan.source,
                limitBytes: partialLimitBytes
            )
            scopeReportRecord = report.sidecarValue
            // `updateAllocation` already re-persisted the sidecar; persist once
            // more so `scope_report` lands beside the state it describes.
            do {
                try persistSidecar()
            } catch {
                progress.append(
                    "disktriage: warning: cannot record scope_report in the sidecar: "
                        + "\(error.localizedDescription)"
                )
            }
            let stdout = plan.asJSON
                ? renderScopeReportJSON(
                    report,
                    image: plan.image,
                    mapfile: plan.mapfile,
                    sidecar: sidecarPath
                )
                : renderScopeReportTTY(report)
            return CLIResult(
                stdout: stdout,
                stderr: progress.joined(separator: "\n") + "\n",
                exitCode: 0
            )
        case .failed(let reason):
            updateAllocation(
                mode: "whole-device",
                stage0: "failed",
                reason: reason
            )
            progress.append(
                "disktriage: scope report: stage 0 failed: \(reason); nothing learned "
                    + "(no allocation, no stage 1 or 2 read)"
            )
            return CLIResult(
                stdout: "",
                stderr: progress.joined(separator: "\n") + "\n",
                exitCode: 1
            )
        case .stopped(let stopped):
            updateAllocation(stage0: "interrupted", reason: stopped.reason.rawValue)
            progress.append(
                "disktriage: scope report: stage 0 \(stopped.reason.rawValue)"
                    + (stopped.launchError.map { ": \($0)" } ?? "")
                    + "; nothing learned"
            )
            return CLIResult(
                stdout: "",
                stderr: progress.joined(separator: "\n") + "\n",
                exitCode: stopped.reason == .launchFailed ? 30 : 1
            )
        }
    }

    /// A pass that never ran (everything was already done) is complete for the
    /// requested scope; the snapshot is evidence, not a fabricated rescue.
    func currentPassResult() -> PassResult {
        let snapshot = dependencies.readMapfile(plan.mapfile).flatMap {
            DdrescueMapfile.parse($0, limitBytes: partialLimitBytes)
        }
        return PassResult(pass: 2, reason: .complete, snapshot: snapshot)
    }

    func runPlainPasses() -> PassResult {
        guard plan.passes.count == 2 else {
            return PassResult(
                pass: 1,
                reason: .launchFailed,
                launchError: "the two-pass command could not be built"
            )
        }
        progress.append("disktriage: pass 1 (\(plan.passes[0].line)) started")
        lastPass = plan.passes[0]
        passReached = 1
        var result = makeSupervisor(plan.passes[0], scope: nil)
            .run(plan.passes[0], applyStopRule: false)
        progress.append(contentsOf: progressLog.drain())
        progress.append("disktriage: pass 1 \(passOutcome(result))")
        if result.reason == .complete {
            passReached = 2
            progress.append("disktriage: pass 2 (\(plan.passes[1].line)) started")
            lastPass = plan.passes[1]
            result = makeSupervisor(plan.passes[1], scope: nil)
                .run(plan.passes[1], applyStopRule: true)
            progress.append(contentsOf: progressLog.drain())
            progress.append("disktriage: pass 2 \(passOutcome(result))")
        }
        return result
    }

    /// Runs a stage from `startPass` (1 or 2). Returns the first non-complete
    /// pass or the last complete one.
    func runStage(
        _ number: Int,
        passes: [DdrescuePass],
        scope: [ByteRange],
        startPass: Int
    ) -> PassResult {
        var result = PassResult(pass: startPass, reason: .complete)
        for pass in passes where pass.pass >= startPass {
            lastPass = pass
            passReached = pass.pass
            progress.append(
                "disktriage: stage \(number) pass \(pass.pass) (\(pass.line)) started"
            )
            result = makeSupervisor(pass, scope: scope)
                .run(pass, applyStopRule: pass.pass == 2)
            progress.append(contentsOf: progressLog.drain())
            progress.append("disktriage: stage \(number) pass \(pass.pass) \(passOutcome(result))")
            if result.reason != .complete { return result }
        }
        return result
    }

    var scope = "whole device"
    var scopeRanges: [ByteRange]? = [ByteRange(position: 0, size: imageLimit)]
    var result: PassResult

    if dependencies.allocationAware {
        switch performStage0() {
        case .stopped(let stopped):
            result = stopped
            updateAllocation(stage0: "interrupted", reason: stopped.reason.rawValue)
            stageReports = [ImagingStageReport(
                stage: 0,
                name: "metadata",
                status: "stopped",
                detail: stopped.reason.rawValue
            )]
        case .failed(let reason):
            progress.append("disktriage: stage 0 failed: \(reason); falling back to whole-device passes")
            updateAllocation(
                mode: "whole-device",
                stage0: "failed",
                reason: reason,
                stage1: "plain",
                stage2: "plain"
            )
            stageReports = [
                ImagingStageReport(stage: 0, name: "metadata", status: "failed", detail: reason),
                ImagingStageReport(
                    stage: 1,
                    name: "used clusters + metadata",
                    status: "not run",
                    detail: "the allocation is unknown; free space was not skipped"
                ),
                ImagingStageReport(
                    stage: 2,
                    name: "rest of the device",
                    status: "plain whole-device passes",
                    detail: nil
                ),
            ]
            scope = "whole device (allocation unknown: \(reason))"
            scopeRanges = [ByteRange(position: 0, size: imageLimit)]
            result = runPlainPasses()
        case .known(let stage0):
            updateAllocation(
                mode: "allocation-aware",
                stage0: "done",
                geometrySource: stage0.geometrySource.rawValue
            )
            stageReports.append(ImagingStageReport(
                stage: 0,
                name: "metadata",
                status: "done",
                detail: "geometry source \(stage0.geometrySource.rawValue)"
            ))

            let usedScope = clipExtents(
                stage0.readExtents + stage0.domain.used,
                to: imageLimit
            )
            let previousAllocation = plan.previousAllocation
            let resumeMode = previousAllocation?.mode == "allocation-aware"

            // Stage 1: used clusters + metadata.
            if resumeMode, previousAllocation?.stage1 == "done" {
                progress.append("disktriage: stage 1 already complete; resuming after it")
                updateAllocation(stage1: "done")
                stageReports.append(ImagingStageReport(
                    stage: 1,
                    name: "used clusters + metadata",
                    status: "done",
                    detail: "already complete"
                ))
            } else {
                let startPass = resumeMode && previousAllocation?.stage1 == "pass2" ? 2 : 1
                updateAllocation(stage1: startPass == 2 ? "pass2" : "pass1")
                let mapfile = plan.image + ".domain-stage1.mapfile"
                let stageOneDomain = clipExtents(stage0.domain.used, to: imageLimit)
                do {
                    let text = DdrescueDomainMapfile.render(
                        domain: stageOneDomain,
                        deviceSize: plan.source.sizeBytes ?? imageLimit
                    )
                    try writeFile(mapfile, Data(text.utf8))
                } catch {
                    result = PassResult(
                        pass: startPass,
                        reason: .launchFailed,
                        launchError: "cannot write \(mapfile): \(error.localizedDescription)"
                    )
                    stageReports.append(ImagingStageReport(
                        stage: 1,
                        name: "used clusters + metadata",
                        status: "failed",
                        detail: result.launchError
                    ))
                    return finishImaging(
                        plan: plan,
                        result: result,
                        stageReports: stageReports,
                        allocation: allocation,
                        scope: scope,
                        scopeRanges: scopeRanges,
                        partialLimitBytes: partialLimitBytes,
                        startedAt: startedAt,
                        passReached: passReached,
                        lastPass: lastPass,
                        progress: progress,
                        now: now
                    )
                }
                let passes = ddrescueStagePasses(
                    rawDevice: plan.rawDevice,
                    image: plan.image,
                    mapfile: plan.mapfile,
                    domainMapfile: mapfile,
                    blockSize: plan.source.blockSize ?? 512,
                    stage: 1,
                    timeoutSeconds: timeoutSeconds,
                    limitBytes: partialLimitBytes,
                    minReadRateBytesPerSecond: plan.minReadRateBytesPerSecond
                )
                result = runStage(1, passes: passes, scope: usedScope, startPass: startPass)
                if result.reason != .complete {
                    updateAllocation(stage1: result.reason == .complete ? "done" : "pass\(passReached)")
                    stageReports.append(ImagingStageReport(
                        stage: 1,
                        name: "used clusters + metadata",
                        status: result.reason.rawValue,
                        detail: result.launchError ?? result.reason.rawValue
                    ))
                    return finishImaging(
                        plan: plan,
                        result: result,
                        stageReports: stageReports,
                        allocation: allocation,
                        scope: scope,
                        scopeRanges: scopeRanges,
                        partialLimitBytes: partialLimitBytes,
                        startedAt: startedAt,
                        passReached: passReached,
                        lastPass: lastPass,
                        progress: progress,
                        now: now
                    )
                }
                updateAllocation(stage1: "done")
                stageReports.append(ImagingStageReport(
                    stage: 1,
                    name: "used clusters + metadata",
                    status: "done",
                    detail: "\(stage0.domain.usedClusters.count) used cluster runs"
                ))
            }
            scope = "used clusters + metadata (free space NOT imaged: --used-only)"
            scopeRanges = usedScope

            // Stage 2: the rest of the device last, skipped with --used-only.
            if plan.usedOnly {
                updateAllocation(stage2: "skipped")
                stageReports.append(ImagingStageReport(
                    stage: 2,
                    name: "rest of the device",
                    status: "skipped by --used-only",
                    detail: "free space is not imaged"
                ))
                result = currentPassResult()
            } else if resumeMode, previousAllocation?.stage2 == "done" {
                progress.append("disktriage: stage 2 already complete")
                updateAllocation(stage2: "done")
                stageReports.append(ImagingStageReport(
                    stage: 2,
                    name: "rest of the device",
                    status: "done",
                    detail: "already complete"
                ))
                result = currentPassResult()
            } else {
                let startPass = resumeMode && previousAllocation?.stage2 == "pass2" ? 2 : 1
                updateAllocation(stage2: startPass == 2 ? "pass2" : "pass1")
                let mapfile = plan.image + ".domain-stage2.mapfile"
                let complement = complementExtents(
                    clipExtents(stage0.domain.used, to: imageLimit),
                    upTo: imageLimit
                )
                do {
                    let text = DdrescueDomainMapfile.render(
                        domain: complement,
                        deviceSize: plan.source.sizeBytes ?? imageLimit
                    )
                    try writeFile(mapfile, Data(text.utf8))
                } catch {
                    result = PassResult(
                        pass: startPass,
                        reason: .launchFailed,
                        launchError: "cannot write \(mapfile): \(error.localizedDescription)"
                    )
                    stageReports.append(ImagingStageReport(
                        stage: 2,
                        name: "rest of the device",
                        status: "failed",
                        detail: result.launchError
                    ))
                    return finishImaging(
                        plan: plan,
                        result: result,
                        stageReports: stageReports,
                        allocation: allocation,
                        scope: scope,
                        scopeRanges: scopeRanges,
                        partialLimitBytes: partialLimitBytes,
                        startedAt: startedAt,
                        passReached: passReached,
                        lastPass: lastPass,
                        progress: progress,
                        now: now
                    )
                }
                let passes = ddrescueStagePasses(
                    rawDevice: plan.rawDevice,
                    image: plan.image,
                    mapfile: plan.mapfile,
                    domainMapfile: mapfile,
                    blockSize: plan.source.blockSize ?? 512,
                    stage: 2,
                    timeoutSeconds: timeoutSeconds,
                    limitBytes: partialLimitBytes,
                    minReadRateBytesPerSecond: plan.minReadRateBytesPerSecond
                )
                result = runStage(2, passes: passes, scope: complement, startPass: startPass)
                if result.reason != .complete {
                    updateAllocation(stage2: "pass\(passReached)")
                    stageReports.append(ImagingStageReport(
                        stage: 2,
                        name: "rest of the device",
                        status: result.reason.rawValue,
                        detail: result.launchError ?? result.reason.rawValue
                    ))
                    return finishImaging(
                        plan: plan,
                        result: result,
                        stageReports: stageReports,
                        allocation: allocation,
                        scope: scope,
                        scopeRanges: scopeRanges,
                        partialLimitBytes: partialLimitBytes,
                        startedAt: startedAt,
                        passReached: passReached,
                        lastPass: lastPass,
                        progress: progress,
                        now: now
                    )
                }
                updateAllocation(stage2: "done")
                stageReports.append(ImagingStageReport(
                    stage: 2,
                    name: "rest of the device",
                    status: "done",
                    detail: nil
                ))
                scope = "whole device"
                scopeRanges = [ByteRange(position: 0, size: imageLimit)]
            }
        }
    } else {
        // An explicitly constructed dependency set that did not opt in. The
        // live path always enables the allocation-aware stages.
        let reason = "the allocation-aware stage 0 is not enabled in this dependency set"
        updateAllocation(
            mode: "whole-device",
            stage0: "not-started",
            reason: reason,
            stage1: "plain",
            stage2: "plain"
        )
        stageReports = [
            ImagingStageReport(stage: 0, name: "metadata", status: "not run", detail: reason),
        ]
        scope = "whole device (allocation unknown: \(reason))"
        // Keep the legacy whole-device rendering for an injected dependency set
        // that did not opt into staging (the older fake-ddrescue tests).
        scopeRanges = nil
        result = runPlainPasses()
    }

    return finishImaging(
        plan: plan,
        result: result,
        stageReports: stageReports,
        allocation: allocation,
        scope: scope,
        scopeRanges: scopeRanges,
        partialLimitBytes: partialLimitBytes,
        startedAt: startedAt,
        passReached: passReached,
        lastPass: lastPass,
        progress: progress,
        now: now
    )
}

/// Builds the summary and renders it. Shared by the normal end and the early
/// exits after a stopped stage.
private func finishImaging(
    plan: ImagingPlan,
    result: PassResult,
    stageReports: [ImagingStageReport],
    allocation: ImageSidecarAllocation,
    scope: String,
    scopeRanges: [ByteRange]?,
    partialLimitBytes: Int64?,
    startedAt: Date,
    passReached: Int,
    lastPass: DdrescuePass?,
    progress: [String],
    now: () -> Date
) -> CLIResult {
    var progress = progress
    let usedOnlyComplete = plan.usedOnly && allocation.mode == "allocation-aware"
    let status: String
    if result.reason == .launchFailed {
        status = "tool-error"
    } else if result.reason == .complete {
        if usedOnlyComplete {
            status = partialLimitBytes.map {
                "used-only partial image complete (first \(partialExtentLabel($0)); free space not imaged)"
            } ?? "used-only image complete (free space not imaged)"
        } else {
            status = partialLimitBytes.map {
                "partial image complete (first \(partialExtentLabel($0)))"
            } ?? "complete"
        }
    } else {
        status = "incomplete"
    }

    let snapshot = result.snapshot
    let accounting = scopeRanges.flatMap { ranges in
        snapshot.map { scopeAccounting(snapshot: $0, scope: ranges) }
    }

    let summary = ImagingSummary(
        status: status,
        exitCode: result.reason == .launchFailed ? 30
            : result.reason == .complete ? 0 : 1,
        image: plan.image,
        mapfile: plan.mapfile,
        sidecar: plan.image + ".disktriage.json",
        rescuedBytes: snapshot?.rescuedBytes,
        failedBytes: snapshot?.failedBytes,
        failedExtents: snapshot?.failedExtents.count,
        badBytes: snapshot?.badBytes,
        badExtents: snapshot?.badExtents.count,
        remainingBytes: snapshot?.remainingBytes,
        remainingExtents: snapshot?.remainingExtents.count,
        elapsedSeconds: now().timeIntervalSince(startedAt),
        passReached: max(passReached, 1),
        stopped: result.reason,
        stopExitCode: result.reason == .stoppedOnItsOwn ? result.exitCode : nil,
        stopTimeout: result.reason == .stoppedOnItsOwn
            ? lastPass.flatMap { ddrescueTimeoutArgument($0.argv) }
            : nil,
        resumeCommand: result.reason == .complete ? nil : resumeCommand(plan),
        stop: result.stop,
        partialLimitBytes: partialLimitBytes,
        deviceBytes: plan.source.sizeBytes,
        minReadRateBytesPerSecond: plan.minReadRateBytesPerSecond,
        scope: scope,
        stages: stageReports,
        allocation: allocation,
        scopeTotalBytes: accounting?.totalBytes,
        scopeRescuedBytes: accounting?.rescuedBytes,
        scopeFailedBytes: accounting?.failedBytes,
        scopeFailedExtents: accounting?.failedExtents,
        scopeBadBytes: accounting?.badBytes,
        scopeBadExtents: accounting?.badExtents,
        scopeRemainingBytes: accounting?.remainingBytes
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
        let key = "\(progress.stage)-\(progress.pass)-\(progress.rescuedBytes)-"
            + "\(progress.failedBytes)-\(progress.badBytes)-\(progress.remainingBytes)"
        guard key != lastKey else { return }
        lastKey = key
        if progress.stage > 0 {
            lines.append(String(
                format: "disktriage: stage %d pass %d: %.1f%% of scope rescued (%@), "
                    + "%@ bad, %@ failed (%d extents), %@ remaining in scope",
                progress.stage,
                progress.pass,
                progress.percent,
                bytes(progress.rescuedBytes),
                bytes(progress.badBytes),
                bytes(progress.failedBytes),
                progress.failedExtents,
                bytes(progress.remainingBytes)
            ))
            return
        }
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
    lines.append(pad("SCOPE", 10) + summary.scope)
    for stage in summary.stages {
        let title = "STAGE \(stage.stage)"
        let detail = stage.detail.map { ": \($0)" } ?? ""
        lines.append(pad(title, 10) + "\(stage.name): \(stage.status)\(detail)")
    }
    if summary.scopeTotalBytes != nil {
        lines.append(pad("RESCUED", 10) + optionalBytes(summary.scopeRescuedBytes)
            + " of " + optionalBytes(summary.scopeTotalBytes) + " in scope")
        lines.append(pad("FAILED", 10)
            + "\(optionalBytes(summary.scopeFailedBytes)) in "
            + "\(optionalCount(summary.scopeFailedExtents)) extents "
            + "(read errors seen; not yet trimmed or scraped)")
        lines.append(pad("BAD", 10)
            + "\(optionalBytes(summary.scopeBadBytes)) in "
            + "\(optionalCount(summary.scopeBadExtents)) extents (confirmed)")
        lines.append(pad("REMAINING", 10) + "\(optionalBytes(summary.scopeRemainingBytes)) in scope")
    } else {
        lines.append(pad("RESCUED", 10) + optionalBytes(summary.rescuedBytes))
        lines.append(pad("FAILED", 10)
            + "\(optionalBytes(summary.failedBytes)) in \(optionalCount(summary.failedExtents)) extents "
            + "(read errors seen; not yet trimmed or scraped)")
        lines.append(pad("BAD", 10)
            + "\(optionalBytes(summary.badBytes)) in \(optionalCount(summary.badExtents)) extents (confirmed)")
        let remaining = summary.remainingBytes.map { bytes($0) } ?? "unknown"
        let extents = summary.remainingExtents.map(String.init) ?? "unknown"
        lines.append(pad("REMAINING", 10) + "\(remaining) in \(extents) extents")
    }
    lines.append(pad("ELAPSED", 10) + String(format: "%.1f s", summary.elapsedSeconds))
    lines.append(pad("PASS", 10) + "reached \(summary.passReached)")
    if let limit = summary.partialLimitBytes {
        lines.append(pad("LIMIT", 10)
            + "first \(gib(limit)) of \(gib(summary.deviceBytes)) — PARTIAL image")
    }
    lines.append(pad("MIN RATE", 10) + minReadRateDetail(summary.minReadRateBytesPerSecond))
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
        "scope": summary.scope,
        "elapsed_seconds": summary.elapsedSeconds,
        "pass_reached": summary.passReached,
        "stopped": summary.stoppedDisplay,
        "partial": summary.isPartial,
        "zero_filled": "unreadable regions are zero-filled in the image; "
            + "a volume-level damage report is the next step",
    ]
    if !summary.stages.isEmpty {
        object["stages"] = summary.stages.map { stage -> [String: Any] in
            var value: [String: Any] = [
                "stage": stage.stage,
                "name": stage.name,
                "status": stage.status,
            ]
            if let detail = stage.detail { value["detail"] = detail }
            return value
        }
    }
    if let allocation = summary.allocation {
        object["allocation"] = [
            "used_only": allocation.usedOnly,
            "mode": allocation.mode,
            "stage0": allocation.stage0,
            "stage0_reason": allocation.stage0Reason.map { $0 as Any } ?? NSNull(),
            "geometry_source": allocation.geometrySource.map { $0 as Any } ?? NSNull(),
            "stage1": allocation.stage1,
            "stage2": allocation.stage2,
        ]
    }
    if let total = summary.scopeTotalBytes { object["scope_bytes"] = total }
    if let rescued = summary.scopeRescuedBytes { object["scope_rescued_bytes"] = rescued }
    if let failed = summary.scopeFailedBytes { object["scope_failed_bytes"] = failed }
    if let extents = summary.scopeFailedExtents { object["scope_failed_extents"] = extents }
    if let bad = summary.scopeBadBytes { object["scope_bad_bytes"] = bad }
    if let extents = summary.scopeBadExtents { object["scope_bad_extents"] = extents }
    if let remaining = summary.scopeRemainingBytes { object["scope_remaining_bytes"] = remaining }
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
    object["min_read_rate_bytes_per_second"] = summary.minReadRateBytesPerSecond ?? NSNull()
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
    if plan.usedOnly { parts.append("--used-only") }
    if plan.override { parts.append("--override") }
    if plan.noGuardCheck { parts.append("--no-guard-check") }
    return parts.joined(separator: " ")
}

// MARK: - Formatting

/// The plan and summary wording for the slow-zone threshold. `nil` is
/// "disabled", never "0 bytes/s" (REQ-0181).
func minReadRateDetail(_ bytesPerSecond: Int64?) -> String {
    guard let bytesPerSecond else {
        return "disabled (no -a in pass 1); deferred zones are left for pass 2"
    }
    let megabytes = bytesPerSecond / 1_000_000
    return "\(bytesPerSecond) bytes/s (\(megabytes) MB/s) in pass 1 only; "
        + "slower zones are left for pass 2"
}

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
