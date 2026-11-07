import Foundation
import DiskTriageCore

/// The two signals the guard ever sends, and only to diskarbitrationd.
public enum GuardSignal: Equatable, Sendable {
    case stop
    case cont
}

/// The injectable process seam. Production talks to `pgrep`, `ps` and `kill`;
/// the suite uses a fake so no real system daemon is ever stopped.
public protocol ProcessSignaling: Sendable {
    /// The pid of `diskarbitrationd`, or nil when it cannot be found.
    func diskArbitrationDaemonPid() -> Int32?
    /// Sends SIGSTOP/SIGCONT. Returns false when the signal could not be sent.
    func send(_ signal: GuardSignal, to pid: Int32) -> Bool
    /// The `ps -o stat=` value, trimmed, or nil when it cannot be read.
    func state(of pid: Int32) -> String?
}

/// The result of trying to suspend diskarbitrationd.
public enum GuardSuspendOutcome: Equatable, Sendable {
    case suspended(pid: Int32, state: String)
    case notSuspended(pid: Int32?, state: String?)
}

/// Suspends diskarbitrationd and verifies the stopped state. The bench check
/// is `case "$(ps -o stat= -p "$DA")" in T*)`, so a state that does not start
/// with T is a failure, never an assumed suspend.
public func suspendDiskArbitrationDaemon(
    _ signaling: any ProcessSignaling
) -> GuardSuspendOutcome {
    guard let pid = signaling.diskArbitrationDaemonPid() else {
        return .notSuspended(pid: nil, state: nil)
    }
    guard signaling.send(.stop, to: pid) else {
        return .notSuspended(pid: pid, state: signaling.state(of: pid))
    }
    let state = signaling.state(of: pid)
    guard let state, isStoppedState(state) else {
        return .notSuspended(pid: pid, state: state)
    }
    return .suspended(pid: pid, state: state)
}

/// Sends SIGCONT. Used only by teardown, and only when teardownDecision says
/// the node list did not grow.
public func resumeDiskArbitrationDaemon(
    _ signaling: any ProcessSignaling,
    pid: Int32
) -> Bool {
    signaling.send(.cont, to: pid)
}

/// `ps -o stat=` prints a T prefix for a stopped process ("T", "T+", "T<").
/// The rule lives in `DiskTriageCore` so the collector's "diskutil would hang"
/// check cannot drift from the guard's.
public func isStoppedState(_ state: String?) -> Bool {
    ProcessState.isStopped(state)
}

/// The exact command the bench tells the operator to run when the disk is
/// still attached and the daemon must stay suspended.
public func manualResumeCommand(pid: Int32) -> String {
    "sudo kill -CONT \(pid)"
}
