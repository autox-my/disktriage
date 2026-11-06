import Foundation

/// The Full Disk Access state machine from diskdoctor.md §7, using the errno
/// meanings measured in docs/p0-runbook.md (Phase A, row 7/8) rather than the
/// plan's older assumption.
///
/// A probe is a real 4096-byte read of the internal disk's raw node. The tool
/// never caches a result across runs: every `disktriage check` and every
/// `disktriage image` re-probes, because a stale GRANTED is worse than no flag
/// (REQ-0061, REQ-0062).
public enum FDAState: String, Codable, Sendable, Equatable {
    case granted = "GRANTED"
    case verified = "VERIFIED"
    case denied = "DENIED"
    case unknown = "UNKNOWN"
}

/// What the raw-device probe actually observed. An absent probe is `notRun`,
/// never an implicit zero or an implicit grant.
public enum FDAProbeEvidence: Equatable, Sendable {
    /// A read returned `bytes`; success requires at least one byte.
    case read(bytes: Int)
    /// The kernel refused the open or the read. The errno is the evidence.
    case failed(errno: Int32, message: String)
    /// The probe could not be attempted (for example no internal disk).
    case notRun(reason: String)

    public var errno: Int32? {
        if case .failed(let errno, _) = self { return errno }
        return nil
    }

    public var isSuccessfulRead: Bool {
        if case .read(let bytes) = self { return bytes > 0 }
        return false
    }
}

/// The state plus the evidence and the remedy the state implies.
public struct FDAStatus: Equatable, Sendable {
    public let state: FDAState
    public let evidence: FDAProbeEvidence
    /// `EACCES`: TCC passed, Unix permissions denied; the read needs root.
    public let needsSudo: Bool
    /// `EPERM` is TCC; `EACCES` and `EINVAL` show TCC passed.
    public let tccPassed: Bool
    /// One line for the self-test table; never a silent zero.
    public let detail: String

    public init(
        state: FDAState,
        evidence: FDAProbeEvidence,
        needsSudo: Bool,
        tccPassed: Bool,
        detail: String
    ) {
        self.state = state
        self.evidence = evidence
        self.needsSudo = needsSudo
        self.tccPassed = tccPassed
        self.detail = detail
    }
}

public enum FDAStateMachine {
    // The measured errno contract. Core stays portable: the numbers come from
    // the runbook, not from a platform header.
    static let eperm: Int32 = 1   // TCC denied Full Disk Access
    static let eacces: Int32 = 13 // TCC passed, Unix permissions denied
    static let einval: Int32 = 22 // access worked; the read was misaligned

    /// Maps one probe (and optionally a second probe from the same run).
    ///
    /// A successful read is GRANTED; a second successful read in the same run
    /// is VERIFIED. EPERM is DENIED. EACCES means the grant is there but the
    /// read needs root, so it stays GRANTED with `needsSudo`. EINVAL means
    /// access worked despite the alignment error. Everything else is UNKNOWN.
    public static func evaluate(
        first: FDAProbeEvidence,
        second: FDAProbeEvidence? = nil
    ) -> FDAStatus {
        switch first {
        case .read(let bytes) where bytes > 0:
            if let second, second.isSuccessfulRead {
                return FDAStatus(
                    state: .verified,
                    evidence: first,
                    needsSudo: false,
                    tccPassed: true,
                    detail: "two \(bytes)-byte reads in this run both succeeded"
                )
            }
            return FDAStatus(
                state: .granted,
                evidence: first,
                needsSudo: false,
                tccPassed: true,
                detail: "read \(bytes) bytes from the internal disk"
            )

        case .read:
            return FDAStatus(
                state: .unknown,
                evidence: first,
                needsSudo: false,
                tccPassed: false,
                detail: "the probe read 0 bytes; that is not evidence of access"
            )

        case .failed(let errno, let message):
            switch errno {
            case eperm:
                return FDAStatus(
                    state: .denied,
                    evidence: first,
                    needsSudo: false,
                    tccPassed: false,
                    detail: "EPERM 1 (\(message)): TCC denied Full Disk Access"
                )
            case eacces:
                return FDAStatus(
                    state: .granted,
                    evidence: first,
                    needsSudo: true,
                    tccPassed: true,
                    detail: "EACCES 13 (\(message)): Full Disk Access looks granted; run with sudo"
                )
            case einval:
                return FDAStatus(
                    state: .granted,
                    evidence: first,
                    needsSudo: false,
                    tccPassed: true,
                    detail: "EINVAL 22 (\(message)): access worked; the read was not block-aligned"
                )
            default:
                return FDAStatus(
                    state: .unknown,
                    evidence: first,
                    needsSudo: false,
                    tccPassed: false,
                    detail: "errno \(errno) (\(message)): access could not be determined"
                )
            }

        case .notRun(let reason):
            return FDAStatus(
                state: .unknown,
                evidence: first,
                needsSudo: false,
                tccPassed: false,
                detail: "the probe did not run: \(reason)"
            )
        }
    }

    /// States in which imaging is blocked.
    public static func blocksImaging(_ state: FDAState) -> Bool {
        state == .denied || state == .unknown
    }
}

/// The onboarding text from diskdoctor.md §7 and the Appendix. Pure: the
/// caller supplies the detected terminal name.
public enum FDAGuidance {
    /// Exactly the command the plan prints (verified spelling, macOS 27.2).
    public static let fullDiskAccessDeepLink =
        #"open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles""#

    /// The Appendix "Degraded (no FDA)" transcript, parameterised by the
    /// terminal the CLI runs in. Empty when imaging is not blocked.
    public static func degradedImagingMessage(state: FDAState, terminal: String) -> String {
        guard FDAStateMachine.blocksImaging(state) else { return "" }

        let headline = state == .denied
            ? "  ! raw device access denied (TCC)"
            : "  ! raw device access could not be verified"

        return [
            headline,
            "    Triage completed without it: verdict still MEDIA.",
            "    Imaging needs Full Disk Access for the process that runs it",
            "    (\(terminal), if you launched this from \(terminal)).",
            "    → System Settings open · relaunch required (grant applies at launch)",
        ].joined(separator: "\n")
    }

    /// The onboarding block for the DENIED and UNKNOWN states: the exact
    /// process to grant, the broad-grant warning, the deep link, and the
    /// launch/next-run rules.
    public static func grantInstructions(
        state: FDAState,
        terminal: String,
        terminalPath: String? = nil
    ) -> [String] {
        guard FDAStateMachine.blocksImaging(state) else { return [] }

        let process = terminalPath.map { "\(terminal) (\($0))" } ?? terminal
        let reason = state == .denied
            ? "Full Disk Access is denied for \(process)."
            : "Full Disk Access could not be verified for \(process)."

        return [
            reason,
            "\(terminal) is a terminal application: granting it is a broad grant — every command run in \(terminal) gets raw-device access.",
            fullDiskAccessDeepLink,
            "relaunch required — the grant applies at launch; re-probing happens on the next run (nothing is cached).",
        ]
    }
}
