import Foundation

/// Renders a `Verdict` for a terminal or as JSON. Presentation only: it reads
/// the same structure the classifier produced, so the human and the JSON output
/// cannot drift (REQ-0007).
public enum Renderer {

    // MARK: - TTY

    /// The day-one transcript. Timestamps are UTC (REQ-0059) unless a caller
    /// passes the local zone for `--local`; no local timezone leaks in by
    /// default.
    public static func tty(
        _ signals: SignalSet,
        _ verdict: Verdict,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
    ) -> String {
        var lines: [String] = []
        let device = signals.device

        lines.append("$ disktriage triage \(device?.bsd ?? "?")")
        lines.append("")

        if let device {
            lines.append(field("DEVICE", device.bsd ?? "?", detail: deviceDetail(device)))
            if let model = device.model { lines.append(field("MODEL", model)) }
            if let serial = device.serial { lines.append(field("SERIAL", serial)) }
            if let bus = busLine(device) { lines.append(field("BUS", bus)) }
            if let age = ageLine(signals) { lines.append(field("AGE", age)) }
        }

        if let smart = signals.smart, smart.status == .ok {
            lines.append("")
            lines.append(section("SMART"))
            if let overall = smart.overall {
                lines.append(smartRow("overall", overall, comment: "← threshold-based; ignore on its own"))
            }
            if let pending = smart.pending {
                let comment = pending > 0
                    ? "← at least \(pending * 512 / 1000) KB the drive cannot currently read"
                    : nil
                lines.append(smartRow("pending sectors", "\(pending)", comment: comment))
            }
            if let reallocated = smart.reallocated {
                lines.append(smartRow("reallocated", "\(reallocated)"))
            }
            if let uncorrectable = smart.uncorrectable {
                lines.append(smartRow("uncorrectable", "\(uncorrectable)"))
            }
            if let raw = smart.rawReadErrors {
                lines.append(smartRow("raw read errors", comma(raw)))
            }
        }

        let errorRows = errorSignalRows(signals, timeZone: timeZone)
        if !errorRows.isEmpty {
            lines.append("")
            lines.append(section("ERROR SIGNALS"))
            lines.append(contentsOf: errorRows)
        }

        let drivers = signals.drivers?.items ?? []
        let ntfs = signals.fs?.type?.lowercased() == "ntfs"
        if !drivers.isEmpty || ntfs {
            lines.append("")
            lines.append(section("FILESYSTEM DRIVERS"))
            for item in drivers {
                let path = item.path ?? "unknown"
                let claims = (item.claims ?? []).map { $0.uppercased() }.joined(separator: ", ")
                let what = claims.isEmpty ? "the volume" : "\(claims) volumes"
                let note = item.thirdParty == true
                    ? "← third-party, claims \(what)"
                    : "← \(what)"
                lines.append("  " + pad(path, 41) + note)
            }
            if ntfs {
                lines.append("  NTFS inspection: ntfs-3g tools on the image (no mount)")
            }
        }

        if !verdict.causes.isEmpty {
            lines.append("")
            lines.append(section("DIFFERENTIAL"))
            for (index, cause) in verdict.causes.enumerated() {
                if index > 0 { lines.append("") }
                lines.append(causeHeader("\(index + 1). \(displayName(cause.causeClass))", cause.confidence))
                for detail in detailLines(cause, signals: signals, verdict: verdict) {
                    lines.append("     " + detail)
                }
            }
            if !verdict.aggravators.isEmpty {
                lines.append("")
                lines.append("  AGGRAVATING FACTOR")
                for aggravator in verdict.aggravators {
                    lines.append(aggravatorHeader(displayName(aggravator.aggravatorClass), aggravator.confidence))
                    for detail in aggravatorDetail(aggravator) {
                        lines.append("     " + detail)
                    }
                }
            }
        }

        lines.append("")
        lines.append("VERDICT")
        if verdict.causes.contains(where: { $0.causeClass == .media && $0.confidence != .low }) {
            lines.append("  The disk is degrading, not dead. The pending-sector count is a floor,")
            lines.append("  not an estimate: the real extent of loss is unknown until the device")
            lines.append("  has been imaged. Do not mount it again.")
        } else {
            for line in wrap(verdict.headline, width: 66) {
                lines.append("  " + line)
            }
        }
        for warning in verdict.warnings {
            for line in wrap("warning: \(warning)", width: 66) {
                lines.append("  " + line)
            }
        }

        if verdict.causes.isEmpty,
           !verdict.evidenceAvailable.isEmpty || !verdict.evidenceUnavailable.isEmpty {
            lines.append("")
            lines.append("EVIDENCE")
            if !verdict.evidenceAvailable.isEmpty {
                lines.append("  available    \(verdict.evidenceAvailable.joined(separator: ", "))")
            }
            if !verdict.evidenceUnavailable.isEmpty {
                lines.append("  unavailable  \(verdict.evidenceUnavailable.joined(separator: ", "))")
            }
        }
        if let note = verdict.unsupportedNote {
            lines.append("")
            for line in wrap(note, width: 66) {
                lines.append("  " + line)
            }
        }

        if let next = verdict.next {
            lines.append("")
            if let low = next.etaLowHours, let high = next.etaHighHours {
                lines.append("NEXT  (~\(low)–\(high) h, estimated from size and bus speed)")
            } else {
                lines.append("NEXT")
            }
            lines.append("  \(next.command)")
            if let serial = signals.device?.serial, serial.count >= 4 {
                lines.append("  (you will be asked to type the last four of the serial: \(serial.suffix(4)))")
            }
            if let inspect = next.inspectCommand, let filename = inspect.split(separator: " ").last {
                lines.append("")
                lines.append("THEN")
                lines.append(pad("  disktriage inspect \(filename)", 36)
                    + "# read-only, ntfs-3g tools on the image, no mount, no third-party driver")
                lines.append(pad("  disktriage copy   \(filename) --to ~/Archive", 47)
                    + "# hashed copy + volume-level damage report")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Degraded (no FDA)

    /// The Appendix's degraded block: triage completed, imaging needs FDA. It
    /// never claims the triage verdict was withheld (diskdoctor.md §7).
    public static func degradedNoFDA(_ signals: SignalSet, _ verdict: Verdict) -> String {
        let bsd = signals.device?.bsd ?? "?"
        let top = verdict.causes.first?.causeClass.rawValue ?? "no actionable fault"
        return [
            "$ disktriage image \(bsd) --to ...",
            "  ! raw device access denied (TCC)",
            "    Triage completed without it: verdict still \(top).",
            "    Imaging needs Full Disk Access for the process that runs it",
            "    (Terminal, if you launched this from Terminal).",
            "    → System Settings open · relaunch required (grant applies at launch)",
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    /// The machine-readable verdict. Keys are sorted so the bytes are stable,
    /// and any timestamp is ISO-8601 UTC.
    public static func json(_ verdict: Verdict) -> String {
        struct Document: Encodable {
            let aggravators: [Aggravator]
            let causes: [Cause]
            let evidenceAvailable: [String]
            let evidenceUnavailable: [String]
            let imagingOffered: Bool
            let next: NextStep?
            let unsupported: String?
            let verdict: Headline
            let warnings: [String]

            enum CodingKeys: String, CodingKey {
                case aggravators, causes, next, unsupported, verdict, warnings
                case evidenceAvailable = "evidence_available"
                case evidenceUnavailable = "evidence_unavailable"
                case imagingOffered = "imaging_offered"
            }

            /// `next` and `unsupported` are written as explicit `null` so a
            /// consumer sees the field even when the verdict has no value for
            /// it; an absent key is not the same as "not applicable".
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(aggravators, forKey: .aggravators)
                try container.encode(causes, forKey: .causes)
                try container.encode(evidenceAvailable, forKey: .evidenceAvailable)
                try container.encode(evidenceUnavailable, forKey: .evidenceUnavailable)
                try container.encode(imagingOffered, forKey: .imagingOffered)
                try container.encode(next, forKey: .next)
                try container.encode(unsupported, forKey: .unsupported)
                try container.encode(verdict, forKey: .verdict)
                try container.encode(warnings, forKey: .warnings)
            }
        }
        struct Headline: Encodable {
            let code: Int
            let headline: String
        }

        let document = Document(
            aggravators: verdict.aggravators,
            causes: verdict.causes,
            evidenceAvailable: verdict.evidenceAvailable,
            evidenceUnavailable: verdict.evidenceUnavailable,
            imagingOffered: verdict.imagingOffered,
            next: verdict.next,
            unsupported: verdict.unsupportedNote,
            verdict: Headline(code: verdict.code.rawValue, headline: verdict.headline),
            warnings: verdict.warnings
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text + "\n"
    }

    // MARK: - Layout

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private static func field(_ label: String, _ value: String) -> String {
        pad(label, 9) + value
    }

    private static func field(_ label: String, _ value: String, detail: String) -> String {
        pad(label, 9) + pad(value, 35) + detail
    }

    private static func section(_ title: String) -> String {
        title + " " + String(repeating: "─", count: max(0, 66 - title.count))
    }

    private static func smartRow(_ label: String, _ value: String, comment: String? = nil) -> String {
        if let comment {
            return "  " + pad(label, 19) + pad(value, 18) + comment
        }
        return "  " + pad(label, 19) + value
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + pad(label, 19) + value
    }

    private static func causeHeader(_ name: String, _ confidence: Confidence) -> String {
        "  " + pad(name, 46) + "confidence: \(confidence.rawValue.uppercased())"
    }

    private static func aggravatorHeader(_ name: String, _ confidence: Confidence) -> String {
        "     " + pad(name, 43) + "confidence: \(confidence.rawValue.uppercased())"
    }

    private static func deviceDetail(_ device: DeviceSignals) -> String {
        guard let size = device.sizeBytes else { return "whole disk" }
        let gib = Double(size) / 1_073_741_824
        return String(format: "whole disk, %.1f GiB", gib)
    }

    private static func busLine(_ device: DeviceSignals) -> String? {
        guard let bus = device.bus else { return nil }
        let upper = bus.uppercased()
        guard let bridge = device.bridge else { return upper }
        let bridgeName: String
        switch bridge.lowercased() {
        case "generic-sata": bridgeName = "generic SATA bridge"
        default: bridgeName = bridge.replacingOccurrences(of: "-", with: " ") + " bridge"
        }
        return "\(upper) — \(bridgeName) (SAT passthrough: \(device.satPassthrough ?? "unknown"))"
    }

    private static func ageLine(_ signals: SignalSet) -> String? {
        guard let smart = signals.smart, smart.status == .ok,
              let hours = smart.powerOnHours, let reallocated = smart.reallocated else {
            return nil
        }
        let events = reallocated == 1 ? "event" : "events"
        return "\(comma(hours)) power-on hours · \(reallocated) reallocated \(events)"
    }

    private static func errorSignalRows(_ signals: SignalSet, timeZone: TimeZone) -> [String] {
        var rows: [String] = []
        if let io = signals.io, io.status == .ok, io.retries != nil || io.timeouts != nil {
            var parts: [String] = []
            if let retries = io.retries { parts.append("retries \(comma(retries))") }
            if let timeouts = io.timeouts { parts.append("timeouts \(comma(timeouts))") }
            rows.append(row("IORegistry", parts.joined(separator: " · ")))
        }
        if let log = signals.log, log.status == .ok,
           let event = log.events?.first(where: { ($0.kind ?? "").contains("medium") }) {
            var value = "medium error, LBA \(event.lba ?? 0)"
            if let count = event.count {
                var window = ""
                if let first = event.firstTime, let last = event.time {
                    window = ", \(hhmm(first, timeZone))–\(hhmm(last, timeZone))"
                } else if let last = event.time {
                    window = ", \(hhmm(last, timeZone))"
                }
                let occurrences = count == 1 ? "occurrence" : "occurrences"
                value += "  (\(count) \(occurrences)\(window))"
            }
            rows.append(row("unified log", value))
        }
        return rows
    }

    private static func displayName(_ causeClass: CauseClass) -> String {
        switch causeClass {
        case .media: return "MEDIA DEGRADATION"
        case .head: return "HEAD / MECHANICAL"
        case .link: return "ENCLOSURE / LINK"
        case .power: return "POWER DELIVERY"
        case .bridge: return "ENCLOSURE / BRIDGE"
        case .filesystem: return "FILESYSTEM DAMAGE"
        case .unknown: return "UNKNOWN"
        }
    }

    private static func displayName(_ aggravatorClass: AggravatorClass) -> String {
        switch aggravatorClass {
        case .driver: return "DRIVER HANG"
        case .smr: return "SMR REBUILD"
        case .encrypted: return "ENCRYPTED VOLUME"
        }
    }

    private static func sourcePhrase(_ source: EvidenceSource) -> String {
        switch source {
        case .smart: return "SMART"
        case .ioStatistics: return "I/O statistics"
        case .kernelLog: return "the kernel log"
        case .userSymptom: return "the user"
        case .filesystemProbe: return "the filesystem probe"
        }
    }

    private static func detailLines(_ cause: Cause, signals: SignalSet, verdict: Verdict) -> [String] {
        switch cause.causeClass {
        case .media:
            return mediaDetail(cause, signals)
        case .link:
            let mediaPresent = verdict.causes.contains { $0.causeClass == .media }
            if let timeouts = signals.io?.timeouts, signals.io?.status == .ok, timeouts > 0, mediaPresent {
                return [
                    "\(timeouts) timeouts could be the bridge, but pending sectors are",
                    "drive-internal. The bridge cannot explain them.",
                ]
            }
            return [
                "Timeouts with no other signal point at the cable, port or enclosure.",
                "Swap them one at a time and retest.",
            ]
        case .bridge:
            return [
                "SMART is hidden by the bridge, so the drive's own health is unknown.",
                "Swap the enclosure and retest before concluding the disk is dead.",
            ]
        case .power:
            return [
                "Resets under load point at power delivery, not the platter.",
                "Retest on a powered hub or a direct port.",
            ]
        case .head:
            return [
                "Mechanical symptoms and resets point at the drive itself.",
                "Power off; do not retry it.",
            ]
        case .filesystem:
            return [
                "The filesystem does not read, with no hardware signal to explain it.",
                "Repair a copy of the image, never the original.",
            ]
        case .unknown:
            return [
                "No usable signal was collected; this is not a health finding.",
                "State what is missing and ask for the next test.",
            ]
        }
    }

    private static func mediaDetail(_ cause: Cause, _ signals: SignalSet) -> [String] {
        var parts: [String] = []
        let smart = signals.smart
        let smartOK = smart?.status == .ok
        if smartOK, let pending = smart?.pending, pending > 0 {
            parts.append("pending=\(pending)")
        }
        if smartOK, let reallocated = smart?.reallocated, reallocated > 0 {
            parts.append("reallocated>0")
        }
        let medium = (signals.log?.status == .ok ? signals.log?.events : nil)?
            .first(where: { ($0.kind ?? "").contains("medium") && $0.lba != nil })
        if medium != nil {
            parts.append("medium errors pinned to one LBA")
        }

        var lines: [String] = []
        if !parts.isEmpty {
            lines.append(parts.joined(separator: ", "))
        }

        let ioDisplayed = signals.io?.status == .ok
            && (signals.io?.retries != nil || signals.io?.timeouts != nil)
        let sources = cause.sources
        if sources.count >= 2 {
            let ioCorroborates = ioDisplayed && !sources.contains(.ioStatistics)
            let ending = ioCorroborates ? ";" : ")."
            lines.append("(two independent sources agree: \(sourcePhrase(sources[0])) and \(sourcePhrase(sources[1]))\(ending)")
            if ioCorroborates {
                lines.append("I/O statistics corroborate).")
            }
        } else if sources.count == 1 {
            lines.append("(one strong source: \(sourcePhrase(sources[0]))).")
        }

        if let fs = signals.fs, fs.type?.lowercased() == "ntfs",
           let lba = medium?.lba, fs.partitionStartLba == lba {
            lines.append("That LBA (\(lba)) is the NTFS boot sector — every mount reads it")
            lines.append("first, which is why the volume dies before it can say anything.")
        }
        return lines
    }

    private static func aggravatorDetail(_ aggravator: Aggravator) -> [String] {
        switch aggravator.aggravatorClass {
        case .driver:
            return [
                "A third-party FS driver may block on a retrying read, which makes",
                "a slow disk look dead.",
            ]
        case .smr:
            return [
                "This model is shingled; rebuilds and imaging take much longer.",
                "Do not treat a slow rebuild as a failing drive.",
            ]
        case .encrypted:
            return [
                "Firmware or volume encryption was detected; the passphrase is needed.",
                "Hand off rather than guessing at the plaintext.",
            ]
        }
    }

    private static func comma(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func hhmm(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        // UTC keeps the explicit Z the Appendix shows; a local render must not
        // claim to be Zulu.
        formatter.dateFormat = timeZone.secondsFromGMT() == 0 ? "HH:mm'Z'" : "HH:mm"
        return formatter.string(from: date)
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > width, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
