import Foundation
import DiskTriageCore

/// Whether `diskutil` can be used at all right now.
///
/// P0 phase C measured that a suspended `diskarbitrationd` makes `diskutil`
/// hang system-wide. Every production path that would otherwise call it asks
/// this one probe first, so the guard's argv shapes (`pgrep -x`, `ps -o
/// stat= -p`) and the T-prefix rule live in one place.
///
/// Only a positive stopped state skips `diskutil`; a failed or unreadable
/// probe is not a guard, and falls through to the normal path.
public struct DiskArbitrationProbe: Sendable {
    public static let stoppedReason = "diskarbitrationd is stopped; diskutil skipped"
    public static let forcedReason = "DISKTRIAGE_FORCE_IOREG=1 (test-only); diskutil skipped"

    private let executor: any CommandExecuting
    /// Test-only: `DISKTRIAGE_FORCE_IOREG=1` exercises the never-DiskArbitration
    /// path on a healthy Mac, so the smoke result is reproducible without
    /// suspending a system daemon.
    public let forceIOReg: Bool

    public init(
        executor: any CommandExecuting = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executor = executor
        self.forceIOReg = environment["DISKTRIAGE_FORCE_IOREG"] == "1"
    }

    public func isStopped() -> Bool {
        let pidResult = executor.run(.pgrepDiskArbitrationDaemon)
        guard pidResult.outcome == .ok,
              let pid = pidResult.stdout
                  .split(whereSeparator: \.isWhitespace)
                  .first
                  .flatMap({ Int32($0) })
        else { return false }

        let stateResult = executor.run(.processState(pid: pid))
        guard stateResult.outcome == .ok else { return false }
        return ProcessState.isStopped(stateResult.stdout)
    }

    /// `nil` when `diskutil` may run; otherwise the reason it must be skipped.
    public func diskutilSkipReason() -> String? {
        if forceIOReg { return Self.forcedReason }
        return isStopped() ? Self.stoppedReason : nil
    }
}
