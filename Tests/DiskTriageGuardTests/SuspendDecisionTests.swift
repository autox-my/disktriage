import Foundation
import Testing
import DiskTriageGuard

/// The signal seam is injected on purpose: the suite must never send SIGSTOP
/// to a real diskarbitrationd (the brief calls this out as a system-wide
/// effect). Every test here drives a fake.
final class FakeProcessSignaling: ProcessSignaling, @unchecked Sendable {
    var pid: Int32?
    var states: [String?]
    var sendSucceeds: Bool
    private(set) var sent: [(GuardSignal, Int32)] = []

    init(pid: Int32?, states: [String?] = [], sendSucceeds: Bool = true) {
        self.pid = pid
        self.states = states
        self.sendSucceeds = sendSucceeds
    }

    func diskArbitrationDaemonPid() -> Int32? { pid }

    func send(_ signal: GuardSignal, to pid: Int32) -> Bool {
        sent.append((signal, pid))
        return sendSucceeds
    }

    func state(of pid: Int32) -> String? {
        guard !states.isEmpty else { return nil }
        return states.removeFirst()
    }
}

struct SuspendDecisionTests {

    @Test("a daemon in state T is suspended, and only SIGSTOP was sent")
    func acceptsAStoppedDaemon() {
        let fake = FakeProcessSignaling(pid: 42, states: ["T"])
        #expect(
            suspendDiskArbitrationDaemon(fake) == .suspended(pid: 42, state: "T")
        )
        #expect(fake.sent.count == 1)
        #expect(fake.sent.first?.0 == .stop)
        #expect(fake.sent.first?.1 == 42)
    }

    @Test("a daemon that did not reach state T is not suspended")
    func refusesASuspendThatDidNotReachStateT() {
        let fake = FakeProcessSignaling(pid: 42, states: ["S"])
        #expect(suspendDiskArbitrationDaemon(fake) == .notSuspended(pid: 42, state: "S"))
    }

    @Test("no diskarbitrationd means no suspend attempt")
    func missingDaemonIsNotSuspended() {
        let fake = FakeProcessSignaling(pid: nil)
        #expect(suspendDiskArbitrationDaemon(fake) == .notSuspended(pid: nil, state: nil))
        #expect(fake.sent.isEmpty)
    }

    @Test("a failed SIGSTOP is not a suspend")
    func aFailedSignalIsNotASuspend() {
        let fake = FakeProcessSignaling(pid: 42, states: ["S"], sendSucceeds: false)
        #expect(suspendDiskArbitrationDaemon(fake) == .notSuspended(pid: 42, state: "S"))
    }

    @Test("ps -o stat= reports a stopped process with a T prefix")
    func theStoppedStateIsTheBenchCasePattern() {
        #expect(isStoppedState("T"))
        #expect(isStoppedState("T+"))
        #expect(isStoppedState("T<"))
        #expect(!isStoppedState("S"))
        #expect(!isStoppedState("Ss"))
        #expect(!isStoppedState("R+"))
        #expect(!isStoppedState(""))
        #expect(!isStoppedState(nil))
    }

    @Test("the manual resume command is the exact one the bench prints")
    func namesTheManualResumeCommand() {
        #expect(manualResumeCommand(pid: 42) == "sudo kill -CONT 42")
    }
}
