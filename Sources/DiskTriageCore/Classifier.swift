import Foundation

/// How much independent evidence supports a cause (diskdoctor.md §5).
///
/// Sources are counted, not attributes: `pending`, `reallocated` and
/// `uncorrectable` are one source (SMART). I/O statistics count only when the
/// input says P0 validated the counters.
public enum Confidence: String, Codable, Sendable, CaseIterable, Comparable {
    case low
    case medium
    case high

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        let order: [Confidence] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Root-cause classes (diskdoctor.md §5). Aggravators are a separate list and
/// never change the root cause.
public enum CauseClass: String, Codable, Sendable, CaseIterable {
    case media = "MEDIA"
    case head = "HEAD"
    case link = "LINK"
    case power = "POWER"
    case bridge = "BRIDGE"
    case filesystem = "FILESYSTEM"
    case unknown = "UNKNOWN"
}

public enum AggravatorClass: String, Codable, Sendable, CaseIterable {
    case driver = "DRIVER"
    case smr = "SMR"
    case encrypted = "ENCRYPTED"
}

/// The independent evidence sources §5 counts. Attribute-level evidence from
/// one section still counts as one source.
public enum EvidenceSource: String, Codable, Sendable, CaseIterable {
    case smart = "SMART"
    case ioStatistics = "I/O statistics"
    case kernelLog = "kernel log"
    case userSymptom = "user symptom"
    case filesystemProbe = "filesystem probe"
}

/// One root-cause hypothesis: class, confidence, the evidence for it, what
/// would falsify it, and the single cheapest next test (diskdoctor.md §3).
public struct Cause: Codable, Equatable, Sendable {
    public let causeClass: CauseClass
    public let confidence: Confidence
    public let evidence: [String]
    public let sources: [EvidenceSource]
    public let falsifiedBy: String
    public let cheapestTest: String
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case confidence, evidence, sources, note
        case causeClass = "class"
        case falsifiedBy = "falsified_by"
        case cheapestTest = "cheapest_test"
    }

    public init(
        _ causeClass: CauseClass,
        _ confidence: Confidence,
        evidence: [String],
        sources: [EvidenceSource],
        falsifiedBy: String,
        cheapestTest: String,
        note: String? = nil
    ) {
        self.causeClass = causeClass
        self.confidence = confidence
        self.evidence = evidence
        self.sources = sources
        self.falsifiedBy = falsifiedBy
        self.cheapestTest = cheapestTest
        self.note = note
    }
}

/// A condition that modifies the advice without being the root cause
/// (diskdoctor.md §5).
public struct Aggravator: Codable, Equatable, Sendable {
    public let aggravatorClass: AggravatorClass
    public let confidence: Confidence
    public let note: String

    enum CodingKeys: String, CodingKey {
        case confidence, note
        case aggravatorClass = "class"
    }

    public init(_ aggravatorClass: AggravatorClass, _ confidence: Confidence, note: String) {
        self.aggravatorClass = aggravatorClass
        self.confidence = confidence
        self.note = note
    }
}

/// The one command the verdict asks for, with the reason and (when it can be
/// derived from size and bus) an ETA range. `command` is a suggestion only; the
/// classifier never runs anything.
public struct NextStep: Codable, Equatable, Sendable {
    public let command: String
    public let why: String
    public let etaLowHours: Int?
    public let etaHighHours: Int?
    public let inspectCommand: String?
    public let copyCommand: String?

    enum CodingKeys: String, CodingKey {
        case command, why
        case etaLowHours = "eta_low_hours"
        case etaHighHours = "eta_high_hours"
        case inspectCommand = "inspect_command"
        case copyCommand = "copy_command"
    }

    public init(
        command: String,
        why: String,
        etaLowHours: Int? = nil,
        etaHighHours: Int? = nil,
        inspectCommand: String? = nil,
        copyCommand: String? = nil
    ) {
        self.command = command
        self.why = why
        self.etaLowHours = etaLowHours
        self.etaHighHours = etaHighHours
        self.inspectCommand = inspectCommand
        self.copyCommand = copyCommand
    }
}

/// Input the classifier needs that is not a hardware signal: where the user
/// would write the image. It changes the suggested command, never the
/// classification.
public struct TriageContext: Equatable, Sendable {
    public let imageDestination: String?

    public init(imageDestination: String? = nil) {
        self.imageDestination = imageDestination
    }
}

/// Classifies a `SignalSet` into a `Verdict` (diskdoctor.md §5).
///
/// Pure: no OS calls, no subprocesses, no filesystem access. An absent signal is
/// never a zero; `denied`, `timeout` and `unsupported` are not measurements.
public func classify(_ signals: SignalSet, context: TriageContext = TriageContext()) -> Verdict {
    let device = signals.device
    let smart = signals.smart
    let smartOK = smart?.status == .ok
    let pending = smartOK ? smart?.pending : nil
    let reallocated = smartOK ? smart?.reallocated : nil
    let uncorrectable = smartOK ? smart?.uncorrectable : nil
    let history = smartOK ? smart?.history : nil

    let ioOK = signals.io?.status == .ok
    let retries = ioOK ? signals.io?.retries : nil
    let timeouts = ioOK ? signals.io?.timeouts : nil
    let ioCounted = ioOK && signals.io?.p0Validated == true

    let logOK = signals.log?.status == .ok
    let events = logOK ? (signals.log?.events ?? []) : []
    let mediumEvents = events.filter { ($0.kind ?? "").contains("medium") && $0.lba != nil }
    let resetCount = events
        .filter { ($0.kind ?? "").contains("reset") }
        .reduce(0) { $0 + ($1.count ?? 1) }

    let fsOK = signals.fs?.status == .ok
    let fsReadable = fsOK ? signals.fs?.readable : nil

    let clicking = signals.symptoms?.clicking == true
    let disappears = signals.symptoms?.disappears == true
    let swapPort = signals.symptoms?.worksOnOtherPort == true
    let swapCable = signals.symptoms?.worksWithOtherCable == true
    let swapEnclosure = signals.symptoms?.worksWithOtherEnclosure == true

    let (available, unavailable) = evidenceLists(signals)
    let aggravators = makeAggravators(signals)

    // [2] media supported? SSD/NVMe/flash/SD are not classified; imaging stays
    // available with a caveat (diskdoctor.md §5, §12).
    if let media = device?.media?.lowercased(), ["ssd", "nvme", "flash", "sd", "sdcard"].contains(media) {
        return Verdict(
            code: .insufficientEvidence,
            headline: "triage not applicable: unsupported media",
            aggravators: aggravators,
            evidenceAvailable: available,
            evidenceUnavailable: unavailable,
            imagingOffered: true,
            unsupportedNote: "UNSUPPORTED: \(media) is not covered by HDD triage; no health classification applies. Imaging remains available with that caveat.",
            next: NextStep(
                command: imageCommand(device, context),
                why: "imaging stays available for unsupported media; no health classification applies"
            )
        )
    }
    if let bus = device?.bus?.lowercased(), bus == "nvme" {
        return Verdict(
            code: .insufficientEvidence,
            headline: "triage not applicable: unsupported media",
            aggravators: aggravators,
            evidenceAvailable: available,
            evidenceUnavailable: unavailable,
            imagingOffered: true,
            unsupportedNote: "UNSUPPORTED: NVMe is not covered by HDD triage; no health classification applies. Imaging remains available with that caveat.",
            next: NextStep(
                command: imageCommand(device, context),
                why: "imaging stays available for unsupported media; no health classification applies"
            )
        )
    }

    var causes: [Cause] = []
    var warnings: [String] = []

    // [4] SMART counters, [5] I/O counters, [6] kernel log.
    let mediaCause = makeMediaCause(
        pending: pending,
        reallocated: reallocated,
        uncorrectable: uncorrectable,
        history: history,
        mediumEvents: mediumEvents,
        retries: ioCounted ? retries : nil
    )
    if let mediaCause {
        causes.append(mediaCause)
    }

    // [7] symptoms decide HEAD; without them the link/power/bridge group stays
    // low confidence and names the cheapest test (diskdoctor.md §5).
    let headCause = makeHeadCause(clicking: clicking, disappears: disappears, resetCount: resetCount, timeouts: timeouts)
    if let headCause {
        causes.append(headCause)
    } else if let group = makeGroupCause(
        smartHidden: smart != nil && !smartOK,
        bridgePresent: device?.bridge != nil || device?.bus?.lowercased() == "usb",
        satPassthrough: device?.satPassthrough,
        timeouts: timeouts,
        resetCount: resetCount,
        swapPort: swapPort,
        swapCable: swapCable,
        swapEnclosure: swapEnclosure
    ) {
        causes.append(group)
    }

    // [9] filesystem on the image only: a fault with no hardware signal.
    if fsReadable == false && mediaCause == nil && headCause == nil {
        causes.append(Cause(
            .filesystem,
            .medium,
            evidence: ["fs=\(signals.fs?.type ?? "unknown") unreadable", "no hardware signal explains it"],
            sources: [.filesystemProbe],
            falsifiedBy: "the image mounts read-only and reads consistently",
            cheapestTest: "inspect the image read-only; repair a copy, never the original"
        ))
    }

    let smartDeniedAndNotRoot = smart?.status == .denied && signals.permissions?.root == false
    let measurementCause = causes.contains {
        [.media, .head, .filesystem].contains($0.causeClass)
    }
    let clean = smartOK
        && pending == 0
        && reallocated == 0
        && uncorrectable == 0
        && fsReadable == true

    if causes.isEmpty {
        // 21 is returned only when no verdict can be formed; otherwise the
        // permission failure is a signal status (diskdoctor.md §5).
        if smartDeniedAndNotRoot {
            return Verdict(
                code: .permissionDenied,
                headline: "could not collect: permission denied (root / FDA)",
                aggravators: aggravators,
                evidenceAvailable: available,
                evidenceUnavailable: unavailable,
                warnings: warnings
            )
        }
        if clean {
            return Verdict(
                code: .noActionableFault,
                headline: "no actionable fault found; SMART PASSED is weak evidence, so this is not a health claim",
                aggravators: aggravators,
                evidenceAvailable: available,
                evidenceUnavailable: unavailable,
                warnings: warnings
            )
        }
        causes.append(unknownCause())
    } else if !measurementCause {
        // [10] nothing measured: state it rather than let a suspicion stand as
        // evidence (the §11 bridge row carries BRIDGE and UNKNOWN together).
        causes.append(unknownCause())
    }

    var codes: [ExitCode] = []
    for cause in causes {
        switch cause.causeClass {
        case .media:
            if cause.confidence == .low {
                warnings.append("MEDIA is low confidence: a stable reallocated count with no history is a warning, not an alarm; watch it and image when convenient")
                codes.append(.noActionableFault)
            } else {
                codes.append(.mediaRisk)
            }
        case .head:
            codes.append(.failing)
        case .link, .power, .bridge:
            codes.append(.bridgeLinkPower)
        case .filesystem:
            codes.append(.filesystemOnly)
        case .unknown:
            codes.append(.insufficientEvidence)
        }
    }
    let code = codes.isEmpty ? .noActionableFault : ExitCode.mostSevere(codes)

    return Verdict(
        code: code,
        headline: headline(for: code, causes: causes),
        causes: causes,
        aggravators: aggravators,
        evidenceAvailable: available,
        evidenceUnavailable: unavailable,
        imagingOffered: true,
        warnings: warnings,
        next: nextStep(for: code, causes: causes, device: device, context: context)
    )
}

// MARK: - Cause construction

/// [8] third-party driver inventory: an aggravator, never the root cause.
private func makeAggravators(_ signals: SignalSet) -> [Aggravator] {
    guard let item = signals.drivers?.items?.first(where: { $0.thirdParty == true }) else {
        return []
    }
    let claims = (item.claims ?? []).map { $0.uppercased() }.joined(separator: ", ")
    let what = claims.isEmpty ? "the volume" : "\(claims) volumes"
    return [Aggravator(
        .driver,
        .medium,
        note: "\(item.path ?? "a third-party filesystem driver") claims \(what); it may block on a retrying read and make a slow disk look dead"
    )]
}

private func makeMediaCause(
    pending: Int?,
    reallocated: Int?,
    uncorrectable: Int?,
    history: SmartHistory?,
    mediumEvents: [LogEvent],
    retries: Int?
) -> Cause? {
    var evidence: [String] = []
    var sources: [EvidenceSource] = []
    var strongSources = 0
    var smartStrong = false
    var smartWeak = false

    if let pending, pending > 0 {
        evidence.append("pending=\(pending)")
        smartStrong = true
    }
    if let uncorrectable, uncorrectable > 0 {
        evidence.append("uncorrectable=\(uncorrectable)")
        smartStrong = true
    }
    if let reallocated, reallocated > 0 {
        if let prior = history?.reallocated, reallocated > prior {
            evidence.append("reallocated=\(reallocated) (rising from \(prior))")
            smartStrong = true
        } else {
            evidence.append("reallocated=\(reallocated)")
            smartWeak = true
        }
    }
    if smartStrong || smartWeak {
        sources.append(.smart)
    }
    if smartStrong { strongSources += 1 }

    if let first = mediumEvents.first, let lba = first.lba {
        evidence.append("medium error @ LBA \(lba)")
        sources.append(.kernelLog)
        strongSources += 1
    }

    if let retries, retries > 0 {
        evidence.append("retries=\(retries)")
        sources.append(.ioStatistics)
    }

    guard !evidence.isEmpty else { return nil }

    let confidence: Confidence
    if strongSources >= 1 && sources.count >= 2 {
        confidence = .high
    } else if strongSources >= 1 {
        confidence = .medium
    } else if sources.count >= 2 {
        confidence = .medium
    } else {
        confidence = .low
    }

    return Cause(
        .media,
        confidence,
        evidence: evidence,
        sources: sources,
        falsifiedBy: "readable image with zero bad areas",
        cheapestTest: "image the device; inspect the mapfile"
    )
}

private func makeHeadCause(clicking: Bool, disappears: Bool, resetCount: Int, timeouts: Int?) -> Cause? {
    var evidence: [String] = []
    var sources: [EvidenceSource] = []

    if clicking {
        evidence.append("clicking")
    }
    if disappears {
        evidence.append("disappears")
    }
    if clicking || disappears {
        sources.append(.userSymptom)
    }
    if resetCount > 0 {
        evidence.append("resets=\(resetCount)")
        sources.append(.kernelLog)
    }
    // A timeout with mechanical symptoms supports HEAD; without them it is the
    // link/power/bridge group.
    if let timeouts, timeouts > 0, clicking || disappears {
        evidence.append("timeouts=\(timeouts)")
        if !sources.contains(.kernelLog) { sources.append(.kernelLog) }
    }

    guard clicking || disappears else { return nil }

    let confidence: Confidence = sources.count >= 2 ? .high : .medium
    return Cause(
        .head,
        confidence,
        evidence: evidence,
        sources: sources,
        falsifiedBy: "a SMART self-test and a full-surface read with no mechanical symptoms",
        cheapestTest: "power off; do not retry the drive",
        note: "mechanical symptoms are user-supplied; software cannot observe them"
    )
}

private func makeGroupCause(
    smartHidden: Bool,
    bridgePresent: Bool,
    satPassthrough: String?,
    timeouts: Int?,
    resetCount: Int,
    swapPort: Bool,
    swapCable: Bool,
    swapEnclosure: Bool
) -> Cause? {
    if swapEnclosure {
        return Cause(
            .bridge,
            .medium,
            evidence: ["works with another enclosure"],
            sources: [.userSymptom],
            falsifiedBy: "the drive fails in a known-good enclosure too",
            cheapestTest: "retest in a known-good enclosure"
        )
    }
    if swapPort || swapCable {
        return Cause(
            .link,
            .medium,
            evidence: [swapPort ? "works on another port" : "works with another cable"],
            sources: [.userSymptom],
            falsifiedBy: "the drive fails on every port and cable",
            cheapestTest: "swap the cable, then the port, and retest"
        )
    }
    if smartHidden && bridgePresent {
        return Cause(
            .bridge,
            .low,
            evidence: ["SMART unreadable through the bridge", "sat_passthrough=\(satPassthrough ?? "unknown")"],
            sources: [],
            falsifiedBy: "SMART readable in another enclosure",
            cheapestTest: "swap the enclosure and retest"
        )
    }
    if let timeouts, timeouts > 0 {
        return Cause(
            .link,
            .low,
            evidence: ["timeouts=\(timeouts)"],
            sources: [],
            falsifiedBy: "resets and timeouts disappear with another cable, port or enclosure",
            cheapestTest: "swap the cable, then the port, and retest"
        )
    }
    if resetCount > 0 {
        return Cause(
            .power,
            .low,
            evidence: ["resets=\(resetCount)"],
            sources: [.kernelLog],
            falsifiedBy: "resets disappear on a powered hub or direct port",
            cheapestTest: "retest on a powered hub or a direct port"
        )
    }
    return nil
}

private func unknownCause() -> Cause {
    Cause(
        .unknown,
        .low,
        evidence: ["no usable signal was collected"],
        sources: [],
        falsifiedBy: "a successful collector run with at least one measurement",
        cheapestTest: "rerun triage with the collectors that were denied or timed out"
    )
}

// MARK: - Verdict text and next action

private func headline(for code: ExitCode, causes: [Cause]) -> String {
    switch code {
    case .mediaRisk:
        return "degrading, not dead; extent of loss unknown until imaged"
    case .failing:
        return "failing; power off and seek professional recovery"
    case .bridgeLinkPower:
        return "bridge/link/power suspicion; swap and retest"
    case .filesystemOnly:
        return "filesystem only; repair a copy of the image"
    case .permissionDenied:
        return "could not collect: permission denied (root / FDA)"
    case .toolError:
        return "tool error; no verdict"
    case .insufficientEvidence:
        return "insufficient evidence; do not infer health from a missing signal"
    case .noActionableFault:
        if causes.contains(where: { $0.causeClass == .media && $0.confidence == .low }) {
            return "possible media degradation at low confidence; watch, do not alarm"
        }
        return "no actionable fault found; this is not a health claim"
    }
}

private func nextStep(for code: ExitCode, causes: [Cause], device: DeviceSignals?, context: TriageContext) -> NextStep? {
    switch code {
    case .mediaRisk:
        let destination = context.imageDestination
        let eta = estimateHours(sizeBytes: device?.sizeBytes, bus: device?.bus)
        return NextStep(
            command: imageCommand(device, context),
            why: "reading the platter once is the only step that cannot be lost to further degradation",
            etaLowHours: eta?.0,
            etaHighHours: eta?.1,
            inspectCommand: destination.map { "disktriage inspect \(($0 as NSString).lastPathComponent)" },
            copyCommand: destination.map { "disktriage copy \(($0 as NSString).lastPathComponent) --to ~/Archive" }
        )
    case .failing:
        return NextStep(
            command: "power off; do not retry the drive",
            why: "mechanical damage gets worse every time the drive spins up"
        )
    case .bridgeLinkPower:
        return NextStep(
            command: device?.bsd.map { "swap cable/enclosure/port, then disktriage triage \($0)" }
                ?? "swap cable/enclosure/port, then retest",
            why: "the swap test is what separates link, power and bridge"
        )
    case .filesystemOnly:
        return NextStep(
            command: "disktriage inspect <image>",
            why: "repair a copy of the image, never the original"
        )
    case .noActionableFault, .insufficientEvidence, .permissionDenied, .toolError:
        return nil
    }
}

private func imageCommand(_ device: DeviceSignals?, _ context: TriageContext) -> String {
    let bsd = device?.bsd ?? "<disk>"
    if let destination = context.imageDestination {
        return "disktriage image \(bsd) --to \(destination)"
    }
    return "disktriage image \(bsd)"
}

/// A rough ETA range from size and bus, for the suggestion only. The image
/// command refines it with a measured rate (diskdoctor.md §8, REQ-0087).
private func estimateHours(sizeBytes: Int64?, bus: String?) -> (Int, Int)? {
    guard let sizeBytes, sizeBytes > 0 else { return nil }
    let rates: (low: Double, high: Double) // MB/s
    switch bus?.lowercased() {
    case "usb": rates = (25, 30)
    case "thunderbolt": rates = (80, 100)
    case "sata", "sata-iii": rates = (100, 150)
    default: rates = (25, 30)
    }
    let low = Int((Double(sizeBytes) / (rates.high * 1_000_000) / 3600).rounded(.up))
    let high = Int((Double(sizeBytes) / (rates.low * 1_000_000) / 3600).rounded(.up))
    return (max(low, 1), max(high, 1))
}

private func evidenceLists(_ signals: SignalSet) -> ([String], [String]) {
    var available: [String] = []
    var unavailable: [String] = []

    func note(_ name: String, _ status: SignalStatus?) {
        guard let status else {
            unavailable.append("\(name): not collected")
            return
        }
        if status == .ok {
            available.append(name)
        } else {
            unavailable.append("\(name): \(status.rawValue)")
        }
    }

    note("SMART", signals.smart?.status)
    note("I/O statistics", signals.io?.status)
    note("kernel log", signals.log?.status)
    note("filesystem probe", signals.fs?.status)
    if signals.symptoms != nil {
        available.append("user symptom")
    } else {
        unavailable.append("user symptom: not supplied")
    }
    return (available, unavailable)
}
