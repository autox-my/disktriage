import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The SIGINT/SIGTERM flag. The handler is a C function, so it only sets a
/// `sig_atomic_t`; every loop that waits checks it. Nothing else runs in the
/// handler, which keeps it async-signal-safe.
private nonisolated(unsafe) var guardInterruptFlag: sig_atomic_t = 0

private func guardSignalHandler(_ signalNumber: Int32) {
    guardInterruptFlag = 1
}

/// Installs the handlers once per process. A guard that is interrupted must
/// still run teardown, so SIGINT/SIGTERM are turned into a flag rather than
/// the default termination.
public func installGuardSignalHandlers() {
    signal(SIGINT, guardSignalHandler)
    signal(SIGTERM, guardSignalHandler)
}

/// True once a SIGINT/SIGTERM has arrived. Never reset by a collector, so a
/// signal during a suspend is not lost before teardown.
public var guardInterrupted: Bool {
    guardInterruptFlag != 0
}

/// Clears the flag at the start of a run.
public func resetGuardInterrupt() {
    guardInterruptFlag = 0
}

/// The live wait: short slices so a signal is noticed promptly, and the
/// deadline is wall-clock, not a sum of slices.
public struct LiveGuardWait: GuardWaiting {
    public init() {}

    public func wait(seconds: Double?) -> Bool {
        installGuardSignalHandlers()
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        while !guardInterrupted {
            if let deadline, Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
