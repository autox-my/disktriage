/// Process exit codes (diskdoctor.md §5).
///
/// 21 and 30 are collection failures: they are returned only when no verdict
/// can be formed. Otherwise they are reported as signal statuses and the
/// verdict code wins.
public enum ExitCode: Int, Codable, Sendable, CaseIterable {
    case noActionableFault = 0
    case mediaRisk = 10
    case failing = 11
    case bridgeLinkPower = 12
    case filesystemOnly = 13
    case insufficientEvidence = 20
    case permissionDenied = 21
    case toolError = 30
}

public extension ExitCode {
    /// A verdict-bearing code. Collection failures are not verdicts.
    var isVerdict: Bool {
        switch self {
        case .permissionDenied, .toolError:
            return false
        case .noActionableFault, .mediaRisk, .failing,
             .bridgeLinkPower, .filesystemOnly, .insufficientEvidence:
            return true
        }
    }

    /// The severity order from diskdoctor.md §5: 11 > 10 > 12 > 13 > 20 > 0.
    var precedence: Int {
        switch self {
        case .failing: return 6
        case .mediaRisk: return 5
        case .bridgeLinkPower: return 4
        case .filesystemOnly: return 3
        case .insufficientEvidence: return 2
        case .noActionableFault: return 1
        // Collection failures compete only among themselves.
        case .toolError: return 2
        case .permissionDenied: return 1
        }
    }

    /// The most severe code among the findings that apply.
    ///
    /// Verdict codes outrank collection failures, so a `MEDIA` verdict is
    /// returned even when SMART was denied. An empty list is "insufficient
    /// evidence", never success: fail closed.
    static func mostSevere(_ codes: [ExitCode]) -> ExitCode {
        let verdicts = codes.filter(\.isVerdict)
        if let worst = verdicts.max(by: { $0.precedence < $1.precedence }) {
            return worst
        }
        if let worst = codes.max(by: { $0.precedence < $1.precedence }) {
            return worst
        }
        return .insufficientEvidence
    }
}

/// Root cause and aggravators stay separate; the verdict carries the exit code
/// and the one-line headline (diskdoctor.md §3, §5).
public struct Verdict: Codable, Equatable, Sendable {
    public let code: ExitCode
    public let headline: String

    public init(code: ExitCode, headline: String) {
        self.code = code
        self.headline = headline
    }

    /// Builds a verdict from every finding that applies, using the §5
    /// precedence rule to choose the reported code.
    public init(adopting codes: [ExitCode], headline: String) {
        self.init(code: .mostSevere(codes), headline: headline)
    }
}
