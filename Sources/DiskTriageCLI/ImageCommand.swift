import Foundation
import DiskTriageCore
import DiskTriageCollectors

/// `disktriage image <disk> --to <file> [--dry-run] [--confirm-serial XXXX]
/// [--confirm-size <GiB>] [--override] [--mapfile <path>] [--json]`
///
/// P2a is dry-run only: it collects the live triage signals, checks the
/// source identity and the destination, and prints the exact `ddrescue`
/// command. It never executes ddrescue and never writes a file.
func image(
    _ arguments: [String],
    executor: any CommandExecuting,
    now: @escaping () -> Date,
    destinationProbe: (any ImageDestinationProbing)?,
    writeFile: (String, Data) throws -> Void,
    imaging: ImagingDependencies?
) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(imageUsage)
    }

    var options = ImageOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--to":
            guard index + 1 < arguments.count else {
                return usageError("--to needs an image file path")
            }
            options.to = arguments[index + 1]
            index += 2
        case "--mapfile":
            guard index + 1 < arguments.count else {
                return usageError("--mapfile needs a path")
            }
            options.mapfile = arguments[index + 1]
            index += 2
        case "--confirm-serial":
            guard index + 1 < arguments.count else {
                return usageError("--confirm-serial needs the last four characters")
            }
            options.confirmSerial = arguments[index + 1]
            index += 2
        case "--confirm-size":
            guard index + 1 < arguments.count else {
                return usageError("--confirm-size needs an integer number of GiB")
            }
            let value = arguments[index + 1]
            guard let size = Int64(value), size > 0 else {
                return usageError("--confirm-size '\(value)' is not a positive integer of GiB")
            }
            options.confirmSize = size
            index += 2
        case "--dry-run":
            options.sawDryRun = true
            index += 1
        case "--no-dry-run":
            options.sawNoDryRun = true
            index += 1
        case "--override":
            options.override = true
            index += 1
        case "--accept-risk":
            options.acceptRisk = true
            index += 1
        case "--no-guard-check":
            options.noGuardCheck = true
            index += 1
        case "--json":
            options.asJSON = true
            index += 1
        default:
            let argument = arguments[index]
            if argument.hasPrefix("-") {
                return usageError("unknown option '\(argument)'")
            }
            guard options.disk == nil else {
                return usageError("image takes one disk, not '\(argument)'")
            }
            guard isWholeDiskName(argument) else {
                return usageError("'\(argument)' is not a whole disk name (for example disk4)")
            }
            options.disk = argument
            index += 1
        }
    }

    if options.sawDryRun && options.sawNoDryRun {
        return usageError("--dry-run and --no-dry-run cannot both be given")
    }
    // Dry-run is the default in the first release (REQ-0048).
    let dryRun = !options.sawNoDryRun
    guard let disk = options.disk else {
        return usageError("image needs a whole disk to image (for example disk4)")
    }
    guard let destination = options.to else {
        return usageError("image needs --to <file>")
    }

    let mapfile = options.mapfile ?? destination + ".mapfile"
    var progress: [String] = []

    // Source identity: model, serial and size are what get confirmed
    // (REQ-0050). `diskN` alone is never the identity.
    let device = DeviceCollector(executor: executor).collect(bsd: disk)
    guard device.status == .ok, let identity = device.identity else {
        progress.append("disktriage: cannot read the identity of \(disk) (\(device.reason ?? device.status.rawValue))")
        return CLIResult(
            stdout: "",
            stderr: progress.joined(separator: "\n") + "\n",
            exitCode: 30
        )
    }
    let source = ImageSource(identity: identity)

    // A triage attempt is required, not a successful verdict (REQ-0044).
    // Inconclusive (exit 20) and hidden SMART never block (REQ-0045).
    var verdict: Verdict?
    var triageAttempted = false
    var triageSkipped = false
    if options.override {
        triageSkipped = true
        progress.append("disktriage: triage check skipped by --override")
    } else {
        if let signals = collectLive(
            disk: disk,
            window: KernelLogCollector.defaultWindow,
            executor: executor,
            now: now,
            progress: &progress
        ) {
            triageAttempted = true
            verdict = classify(signals, context: TriageContext(imageDestination: destination))
        }
    }

    let unsupportedLabel = MediaSupport.unsupportedLabel(media: source.media, bus: source.bus)

    let facts = (destinationProbe ?? SystemImageDestinationProbe(executor: executor))
        .probe(destination: destination, mapfile: mapfile)
    let checks = assessDestination(facts: facts, source: source)

    let confirmation = confirmationState(options: options, source: source)

    var passes: [DdrescuePass] = []
    var eta: ETARange?
    var toolError: String?
    if let blockSize = source.blockSize, let size = source.sizeBytes {
        passes = ddrescuePasses(
            rawDevice: rawDeviceNode(for: source.bsd),
            image: destination,
            mapfile: mapfile,
            blockSize: blockSize
        )
        let bus = assumedBusSpeed(bus: source.bus)
        eta = etaRange(
            deviceBytes: size,
            lowBytesPerSecond: bus.lowBytesPerSecond,
            highBytesPerSecond: bus.highBytesPerSecond,
            basis: bus.basis
        )
    } else if source.blockSize == nil {
        toolError = "the device block size was not collected; the exact command cannot be built"
    } else {
        toolError = "the device size was not collected; the plan cannot be completed"
    }

    var reasons: [String] = []
    if !triageAttempted && !triageSkipped {
        reasons.append("the triage attempt failed; rerun triage or pass --override")
    }
    if !confirmation.satisfied {
        reasons.append(confirmation.instruction)
    }
    for check in checks where check.outcome != .pass {
        reasons.append("\(check.name): \(check.detail)")
    }

    let status: String
    let exitCode: Int32
    if let toolError {
        status = "tool-error"
        exitCode = 30
        reasons.append(toolError)
    } else if reasons.isEmpty {
        status = "ok"
        exitCode = 0
    } else {
        status = "refused"
        exitCode = 2
    }

    if !dryRun {
        if let toolError {
            return CLIResult(
                stdout: "",
                stderr: "disktriage: \(toolError)\n",
                exitCode: 30
            )
        }
        let plan = ImagingPlan(
            disk: disk,
            rawDevice: rawDeviceNode(for: source.bsd),
            image: destination,
            mapfile: mapfile,
            source: source,
            passes: passes,
            destinationChecks: checks,
            triageAttempted: triageAttempted || triageSkipped,
            confirmationInstruction: confirmation.satisfied ? nil : confirmation.instruction,
            asJSON: options.asJSON,
            acceptRisk: options.acceptRisk,
            noGuardCheck: options.noGuardCheck,
            override: options.override,
            confirmSerial: options.confirmSerial,
            confirmSize: options.confirmSize
        )
        return runImaging(
            plan,
            dependencies: imaging,
            executor: executor,
            writeFile: writeFile,
            now: now
        )
    }

    if options.asJSON {
        let output = renderJSON(
            status: status,
            source: source,
            destination: destination,
            mapfile: mapfile,
            triageAttempted: triageAttempted,
            triageSkipped: triageSkipped,
            verdict: verdict,
            unsupportedLabel: unsupportedLabel,
            checks: checks,
            confirmation: confirmation,
            eta: eta,
            passes: passes,
            reasons: reasons
        )
        return CLIResult(
            stdout: output,
            stderr: progress.joined(separator: "\n") + "\n",
            exitCode: exitCode
        )
    }

    let output = renderTTY(
        status: status,
        source: source,
        destination: destination,
        mapfile: mapfile,
        triageAttempted: triageAttempted,
        triageSkipped: triageSkipped,
        verdict: verdict,
        unsupportedLabel: unsupportedLabel,
        checks: checks,
        confirmation: confirmation,
        eta: eta,
        passes: passes,
        reasons: reasons
    )
    return CLIResult(
        stdout: output,
        stderr: progress.joined(separator: "\n") + "\n",
        exitCode: exitCode
    )
}

// MARK: - Arguments

private struct ImageOptions {
    var disk: String?
    var to: String?
    var mapfile: String?
    var confirmSerial: String?
    var confirmSize: Int64?
    var override = false
    var acceptRisk = false
    var noGuardCheck = false
    var asJSON = false
    var sawDryRun = false
    var sawNoDryRun = false
}

// MARK: - Confirmation

private struct ConfirmationState {
    enum Method: String {
        case serial
        case size
        case unavailable
    }

    let method: Method
    let required: String
    let satisfied: Bool
    let instruction: String
}

private func confirmationState(options: ImageOptions, source: ImageSource) -> ConfirmationState {
    if let last4 = source.serialLast4 {
        let given = options.confirmSerial?.trimmingCharacters(in: .whitespacesAndNewlines)
        let satisfied = given?.caseInsensitiveCompare(last4) == .orderedSame
        return ConfirmationState(
            method: .serial,
            required: last4,
            satisfied: satisfied,
            instruction: "confirmation required: pass --confirm-serial \(last4) "
                + "(the last four characters of the serial)"
        )
    }

    if let gib = source.sizeGiB {
        let satisfied = options.confirmSize == gib
        return ConfirmationState(
            method: .size,
            required: String(gib),
            satisfied: satisfied,
            instruction: "confirmation required: pass --confirm-size \(gib) "
                + "(serial unreadable; integer GiB)"
        )
    }

    return ConfirmationState(
        method: .unavailable,
        required: "?",
        satisfied: false,
        instruction: "cannot confirm the source: no serial and no size were collected"
    )
}

// MARK: - TTY

private func renderTTY(
    status: String,
    source: ImageSource,
    destination: String,
    mapfile: String,
    triageAttempted: Bool,
    triageSkipped: Bool,
    verdict: Verdict?,
    unsupportedLabel: String?,
    checks: [DestinationCheck],
    confirmation: ConfirmationState,
    eta: ETARange?,
    passes: [DdrescuePass],
    reasons: [String]
) -> String {
    var lines: [String] = []
    lines.append("$ disktriage image \(source.bsd) --to \(destination) --dry-run")
    lines.append("")

    lines.append(field("DEVICE", source.bsd))
    lines.append(field("MODEL", source.model ?? "unknown"))
    lines.append(field("SERIAL", source.serial ?? "unreadable (confirm by size)"))
    lines.append(field("SIZE", sizeDetail(source.sizeBytes)))
    if let bus = source.bus { lines.append(field("BUS", bus)) }
    if let media = source.media { lines.append(field("MEDIA", media)) }

    if triageSkipped {
        lines.append(field("TRIAGE", "skipped by --override (the triage requirement is explicitly waived)"))
    } else if triageAttempted, let verdict {
        let inconclusive = verdict.code == .insufficientEvidence
        lines.append(field(
            "TRIAGE",
            "attempted · exit \(verdict.code.rawValue)"
                + (inconclusive ? " · inconclusive does not block imaging" : "")
        ))
    } else {
        lines.append(field("TRIAGE", "not attempted (the collection failed)"))
    }

    if let unsupportedLabel {
        lines.append(field(
            "CAVEAT",
            "\(unsupportedLabel) is unsupported media: no health classification applies; "
                + "imaging is still allowed (plan §6)."
        ))
    }

    lines.append("")
    lines.append("DESTINATION  \(destination)")
    lines.append("  " + pad("mapfile", 24) + mapfile)
    for check in checks {
        lines.append(
            "  " + pad(check.name, 24) + pad(check.outcome.rawValue, 9) + check.detail
        )
    }

    lines.append("")
    if confirmation.satisfied {
        switch confirmation.method {
        case .serial:
            lines.append(field("CONFIRM", "serial last four confirmed (\(confirmation.required))"))
        case .size:
            lines.append(field("CONFIRM", "size confirmed (\(confirmation.required) GiB)"))
        case .unavailable:
            lines.append(field("CONFIRM", confirmation.instruction))
        }
    } else {
        lines.append(field("CONFIRM", confirmation.instruction))
    }

    lines.append("")
    lines.append(field(
        "GUARD",
        "start 'disktriage guard' before connecting the disk; the mount must be held "
            + "before the first read (guard arrives later)."
    ))
    lines.append(field(
        "FDA",
        "the process that runs ddrescue needs Full Disk Access "
            + "(the terminal app if you launched this from one)."
    ))

    if let eta {
        lines.append("")
        lines.append(field(
            "ETA",
            "\(durationRange(low: eta.lowSeconds, high: eta.highSeconds)) pass 1 only, "
                + "\(eta.basis); pass 2 adds time for unreadable regions."
        ))
    }

    lines.append("")
    if passes.isEmpty {
        lines.append("PASS 1 / PASS 2  not built: the block size or size is unknown")
    } else {
        for pass in passes {
            let label = pass.pass == 1 ? "PASS 1 (fast sweep, -n)" : "PASS 2 (scrape, -r3)"
            lines.append(label)
            lines.append("  " + pass.line)
            if pass.pass == 1 { lines.append("") }
        }
    }

    lines.append("")
    if status == "ok" {
        lines.append("RESULT    ok; dry-run printed the plan and executed nothing")
    } else {
        lines.append("RESULT    \(status) (\(reasons.count) reason\(reasons.count == 1 ? "" : "s")); "
            + "dry-run printed the plan and executed nothing")
        for reason in reasons {
            lines.append("  - " + reason)
        }
    }

    return lines.joined(separator: "\n") + "\n"
}

private func field(_ label: String, _ value: String) -> String {
    pad(label, 10) + value
}

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}

private func sizeDetail(_ bytes: Int64?) -> String {
    guard let bytes else { return "unknown" }
    return "\(gib(bytes)) (\(bytes) bytes)"
}

private func durationRange(low: Double, high: Double) -> String {
    if high < 60 {
        return String(format: "~%.0f–%.0f s", low, high)
    }
    if high < 3_600 {
        return String(format: "~%.0f–%.0f min", low / 60, high / 60)
    }
    return String(format: "~%.1f–%.1f h", low / 3_600, high / 3_600)
}

// MARK: - JSON

private func renderJSON(
    status: String,
    source: ImageSource,
    destination: String,
    mapfile: String,
    triageAttempted: Bool,
    triageSkipped: Bool,
    verdict: Verdict?,
    unsupportedLabel: String?,
    checks: [DestinationCheck],
    confirmation: ConfirmationState,
    eta: ETARange?,
    passes: [DdrescuePass],
    reasons: [String]
) -> String {
    struct Document: Encodable {
        let dryRun: Bool
        let status: String
        let source: Source
        let triage: Triage
        let caveat: String?
        let destination: Destination
        let confirmation: Confirmation
        let eta: ETA?
        let passes: [String]
        let reasons: [String]

        enum CodingKeys: String, CodingKey {
            case dryRun = "dry_run"
            case status, source, triage, caveat, destination, confirmation, eta, passes, reasons
        }

        struct Source: Encodable {
            let bsd: String
            let model: String?
            let serial: String?
            let sizeBytes: Int64?
            let blockSize: Int64?
            let bus: String?
            let media: String?
            let rawDevice: String

            enum CodingKeys: String, CodingKey {
                case bsd, model, serial, bus, media
                case sizeBytes = "size_bytes"
                case blockSize = "block_size"
                case rawDevice = "raw_device"
            }
        }

        struct Triage: Encodable {
            let attempted: Bool
            let overridden: Bool
            let exitCode: Int?
            let inconclusive: Bool
            let unsupportedMedia: String?

            enum CodingKeys: String, CodingKey {
                case attempted, overridden, inconclusive
                case exitCode = "exit_code"
                case unsupportedMedia = "unsupported_media"
            }
        }

        struct Destination: Encodable {
            let path: String
            let mapfile: String
            let checks: [Check]
        }

        struct Check: Encodable {
            let name: String
            let outcome: String
            let detail: String
        }

        struct Confirmation: Encodable {
            let method: String
            let required: String
            let satisfied: Bool

            enum CodingKeys: String, CodingKey {
                case method, required, satisfied
            }
        }

        struct ETA: Encodable {
            let lowSeconds: Double
            let highSeconds: Double
            let basis: String

            enum CodingKeys: String, CodingKey {
                case basis
                case lowSeconds = "low_seconds"
                case highSeconds = "high_seconds"
            }
        }
    }

    let document = Document(
        dryRun: true,
        status: status,
        source: Document.Source(
            bsd: source.bsd,
            model: source.model,
            serial: source.serial,
            sizeBytes: source.sizeBytes,
            blockSize: source.blockSize,
            bus: source.bus,
            media: source.media,
            rawDevice: rawDeviceNode(for: source.bsd)
        ),
        triage: Document.Triage(
            attempted: triageAttempted,
            overridden: triageSkipped,
            exitCode: verdict?.code.rawValue,
            inconclusive: verdict?.code == .insufficientEvidence,
            unsupportedMedia: unsupportedLabel
        ),
        caveat: unsupportedLabel.map { label in
            "\(label) is unsupported media: no health classification applies; imaging is still allowed (plan §6)."
        },
        destination: Document.Destination(
            path: destination,
            mapfile: mapfile,
            checks: checks.map { Document.Check(name: $0.name, outcome: $0.outcome.rawValue, detail: $0.detail) }
        ),
        confirmation: Document.Confirmation(
            method: confirmation.method.rawValue,
            required: confirmation.required,
            satisfied: confirmation.satisfied
        ),
        eta: eta.map { Document.ETA(lowSeconds: $0.lowSeconds, highSeconds: $0.highSeconds, basis: $0.basis) },
        passes: passes.map(\.line),
        reasons: reasons
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(document),
          let text = String(data: data, encoding: .utf8)
    else {
        return "{}\n"
    }
    return text + "\n"
}

private let imageUsage = "usage: disktriage image <disk> --to <file> [options]\n"
    + "\n"
    + "Prints the exact ddrescue command without executing it. Dry-run is the\n"
    + "default; --no-dry-run runs the two supervised passes with a mapfile and\n"
    + "resume.\n"
    + "\n"
    + "  --to <file>             image destination (never a device node)\n"
    + "  --mapfile <path>        ddrescue mapfile, default <image>.mapfile\n"
    + "  --confirm-serial <4>    the last four characters of the serial\n"
    + "  --confirm-size <GiB>    the size, when the serial is unreadable\n"
    + "  --override              skip the triage-attempt requirement explicitly\n"
    + "  --dry-run               print the command; do not execute (default)\n"
    + "  --no-dry-run            run the two passes; needs root and --accept-risk\n"
    + "  --accept-risk           read a failing drive anyway; that can finish the\n"
    + "                          drive off (plan §12)\n"
    + "  --no-guard-check        proceed without a stopped diskarbitrationd or a\n"
    + "                          running 'disktriage guard'; a probe read may\n"
    + "                          already have happened\n"
    + "  --json                  print the plan or summary as JSON\n"
