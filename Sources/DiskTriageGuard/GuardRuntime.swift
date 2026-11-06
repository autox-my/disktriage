import Foundation

/// One mount-approval decision, as logged.
public struct GuardDecisionRecord: Equatable, Sendable {
    public let bsd: String
    public let description: DiskDescription
    public let verdict: GuardVerdict

    public init(bsd: String, description: DiskDescription, verdict: GuardVerdict) {
        self.bsd = bsd
        self.description = description
        self.verdict = verdict
    }
}

/// Everything the DiskArbitration session reports while the guard runs.
public enum GuardEvent: Equatable, Sendable {
    case decision(GuardDecisionRecord)
    case appeared(bsd: String, description: DiskDescription)
    case changed(bsd: String, keys: [String], description: DiskDescription)
}

public enum GuardRunOutcome: Equatable, Sendable {
    case elapsed
    case interrupted
    case failed(String)
}

/// The dissent runtime. The live implementation owns the DiskArbitration
/// session; the suite injects a fake so no callback is registered.
public protocol DissentRunning: Sendable {
    /// Runs for `seconds`, or until interrupted when nil.
    func run(
        seconds: Double?,
        onEvent: @escaping @Sendable (GuardEvent) -> Void
    ) -> GuardRunOutcome
}

/// Waits for a bounded time or until SIGINT/SIGTERM. Returns true when
/// interrupted. Injected so suspend teardown is testable without signals.
public protocol GuardWaiting: Sendable {
    func wait(seconds: Double?) -> Bool
}
