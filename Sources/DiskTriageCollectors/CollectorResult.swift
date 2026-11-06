import Foundation

/// How a collector's subprocess ended. `timeout`, `denied`, `notFound` and
/// `policyRejected` are evidence about the collection, not measurements
/// (diskdoctor.md §2.3, §2.7).
public enum CollectOutcome: String, Codable, Sendable, Equatable {
    case ok
    case timeout
    case error
    case denied
    case notFound
    /// The argv was not on the read-only allow-list, so it was never executed.
    case policyRejected
}

/// One collector subprocess result.
///
/// Output is captured concurrently and capped at a byte limit; `stdout` and
/// `stderr` stay valid even when the cap was hit, and the truncation is flagged
/// rather than silently hiding it.
public struct CollectorResult: Sendable, Equatable {
    public let outcome: CollectOutcome
    public let exitCode: Int32?
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let durationMs: Int
    /// Set only when `outcome == .policyRejected`.
    public let policyViolation: PolicyViolation?

    public init(
        outcome: CollectOutcome,
        exitCode: Int32? = nil,
        stdout: String = "",
        stderr: String = "",
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        durationMs: Int = 0,
        policyViolation: PolicyViolation? = nil
    ) {
        self.outcome = outcome
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.durationMs = durationMs
        self.policyViolation = policyViolation
    }

    /// A successful recording, used by tests and by callers that already hold
    /// the output.
    public static func ok(_ stdout: String = "", stderr: String = "", exitCode: Int32 = 0) -> CollectorResult {
        CollectorResult(outcome: .ok, exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    public static func timeout() -> CollectorResult {
        CollectorResult(outcome: .timeout)
    }

    public static func denied(_ stderr: String = "") -> CollectorResult {
        CollectorResult(outcome: .denied, stderr: stderr)
    }
}
