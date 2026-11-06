import Foundation
import Testing
import DiskTriageGuard

// The guard command is driven entirely through fakes: no DiskArbitration
// session, no real diskarbitrationd, no signal, no disk.

final class FakeDissent: DissentRunning, @unchecked Sendable {
    var events: [GuardEvent]
    var outcome: GuardRunOutcome
    private(set) var ran = false
    private(set) var requestedSeconds: Double?

    init(events: [GuardEvent] = [], outcome: GuardRunOutcome = .elapsed) {
        self.events = events
        self.outcome = outcome
    }

    func run(
        seconds: Double?,
        onEvent: @escaping @Sendable (GuardEvent) -> Void
    ) -> GuardRunOutcome {
        ran = true
        requestedSeconds = seconds
        for event in events { onEvent(event) }
        return outcome
    }
}

final class FakeNodes: RawDiskNodeProviding, @unchecked Sendable {
    var sequence: [Set<String>]
    private(set) var calls = 0

    init(_ sequence: [Set<String>]) {
        self.sequence = sequence
    }

    func rawDiskNodes() -> Set<String> {
        calls += 1
        guard sequence.count > 1 else { return sequence.first ?? [] }
        return sequence.removeFirst()
    }
}

final class FakeWait: GuardWaiting, @unchecked Sendable {
    var interrupted: Bool
    private(set) var requestedSeconds: Double?
    private(set) var calls = 0

    init(interrupted: Bool = false) {
        self.interrupted = interrupted
    }

    func wait(seconds: Double?) -> Bool {
        calls += 1
        requestedSeconds = seconds
        return interrupted
    }
}

func usbNTFSDecision() -> GuardEvent {
    .decision(
        GuardDecisionRecord(
            bsd: "disk8s2",
            description: DiskDescription(
                isInternal: false,
                protocolName: "USB",
                volumeKind: "iboysoft_NTFS"
            ),
            verdict: .dissent
        )
    )
}

func internalDecision() -> GuardEvent {
    .decision(
        GuardDecisionRecord(
            bsd: "disk0s2",
            description: DiskDescription(
                isInternal: true,
                protocolName: "Apple Fabric",
                volumeKind: "APFS"
            ),
            verdict: .approve
        )
    )
}

struct GuardCommandTests {

    @Test("not root, protection requested: the first line never claims protection, exit 30")
    func notRootNeverClaimsProtectionAndExits30() {
        let recorder = GuardRecorder()
        let result = runGuard(
            arguments: ["--seconds", "1"],
            isRoot: false,
            dissent: FakeDissent(),
            output: recorder.output
        )

        #expect(result.exitCode == 30)
        #expect(recorder.stderr.first == "mode=dissent protection: NOT ACTIVE (not root)")
        #expect(!recorder.stderr.contains { $0.contains("protection: ACTIVE") })
        #expect(recorder.stderr.contains { $0.contains("sudo disktriage guard --seconds 1") })
    }

    @Test("not root without --seconds refuses before idling unprotected")
    func notRootUnboundedRefusesBeforeRunning() {
        let recorder = GuardRecorder()
        let dissent = FakeDissent()
        let result = runGuard(
            arguments: [],
            isRoot: false,
            dissent: dissent,
            output: recorder.output
        )

        #expect(result.exitCode == 30)
        #expect(!dissent.ran, "an unbounded unprotected guard has nothing to protect")
        #expect(recorder.stderr.contains { $0.contains("sudo disktriage guard") })
    }

    @Test("not root with --seconds still observes, then exits 30")
    func notRootWithSecondsObservesBeforeRefusing() {
        let recorder = GuardRecorder()
        let dissent = FakeDissent(events: [usbNTFSDecision()])
        let result = runGuard(
            arguments: ["--seconds", "1"],
            isRoot: false,
            dissent: dissent,
            output: recorder.output
        )

        #expect(dissent.ran, "the dry observation ran")
        #expect(recorder.stderr.contains {
            $0 == "decision bsd=disk8s2 protocol=USB internal=false fs=iboysoft_NTFS verdict=dissent"
        })
        #expect(result.exitCode == 30, "protection was requested and is not active")
    }

    @Test("--observe without root is the observation-only run that exits 0")
    func observeWithoutRootExitsZero() {
        let recorder = GuardRecorder()
        let dissent = FakeDissent(events: [usbNTFSDecision()])
        let result = runGuard(
            arguments: ["--observe", "--seconds", "1"],
            isRoot: false,
            dissent: dissent,
            output: recorder.output
        )

        #expect(dissent.ran)
        #expect(result.exitCode == 0)
        #expect(recorder.stderr.first == "mode=dissent protection: NOT ACTIVE (not root; observation only)")
        #expect(!recorder.stderr.contains { $0.contains("protection: ACTIVE") })
    }

    @Test("root in dissent mode claims ACTIVE and logs one line per decision")
    func rootDissentClaimsActiveAndLogsDecisions() {
        let recorder = GuardRecorder()
        let dissent = FakeDissent(events: [usbNTFSDecision(), internalDecision()])
        let result = runGuard(
            arguments: ["--seconds", "2"],
            isRoot: true,
            dissent: dissent,
            output: recorder.output
        )

        #expect(result.exitCode == 0)
        #expect(recorder.stderr.first == "mode=dissent protection: ACTIVE")
        #expect(dissent.requestedSeconds == 2)
        #expect(recorder.stderr.contains {
            $0 == "decision bsd=disk8s2 protocol=USB internal=false fs=iboysoft_NTFS verdict=dissent"
        })
        #expect(recorder.stderr.contains {
            $0 == "decision bsd=disk0s2 protocol=Apple Fabric internal=true fs=APFS verdict=approve"
        })
    }

    // REQ-0072
    @Test("REQ0072 guard says it must start before the disk is connected")
    func REQ0072_saysStartBeforeConnectingTheDisk() {
        let recorder = GuardRecorder()
        _ = runGuard(
            arguments: ["--seconds", "1"],
            isRoot: true,
            dissent: FakeDissent(),
            output: recorder.output
        )
        #expect(recorder.stderr.contains { $0.contains("before connecting the disk") })
        #expect(recorder.stderr.contains { $0.contains("probe reads") })
    }

    @Test("--json prints one object per decision and a final summary on stdout")
    func jsonPrintsDecisionsThenASummary() throws {
        let recorder = GuardRecorder()
        let result = runGuard(
            arguments: ["--seconds", "2", "--json"],
            isRoot: true,
            dissent: FakeDissent(events: [usbNTFSDecision(), internalDecision()]),
            output: recorder.output
        )

        #expect(result.exitCode == 0)
        let objects = try recorder.stdout.map { line -> [String: Any] in
            try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "every stdout line is a JSON object: \(line)"
            )
        }
        #expect(objects.count == 3, "two decisions and the summary")

        let first = try #require(objects.first)
        #expect(first["event"] as? String == "decision")
        #expect(first["bsd"] as? String == "disk8s2")
        #expect(first["verdict"] as? String == "dissent")
        #expect(first["fs"] as? String == "iboysoft_NTFS")

        let summary = try #require(objects.last)
        #expect(summary["event"] as? String == "summary")
        #expect(summary["mode"] as? String == "dissent")
        #expect(summary["protection"] as? String == "active")
        #expect(summary["decisions"] as? Int == 2)
        #expect(summary["dissents"] as? Int == 1)
        #expect(summary["seconds"] as? Int == 2)
    }

    @Test("suspend without root refuses before touching any process")
    func suspendWithoutRootNeverSignals() {
        let recorder = GuardRecorder()
        let signaling = FakeProcessSignaling(pid: 42, states: ["T"])
        let result = runGuard(
            arguments: ["--suspend", "--seconds", "1"],
            isRoot: false,
            signaling: signaling,
            output: recorder.output
        )

        #expect(result.exitCode == 30)
        #expect(signaling.sent.isEmpty, "no SIGSTOP is ever sent without root")
        #expect(recorder.stderr.first == "mode=suspend protection: NOT ACTIVE (not root)")
        #expect(recorder.stderr.contains {
            $0.contains("sudo disktriage guard --suspend --seconds 1")
        })
        #expect(!recorder.stderr.contains { $0.contains("protection: ACTIVE") })
    }

    @Test("suspend refuses to continue when diskarbitrationd is not in state T")
    func suspendRefusesWhenTheDaemonIsNotStopped() {
        let recorder = GuardRecorder()
        let signaling = FakeProcessSignaling(pid: 42, states: ["S"])
        let wait = FakeWait()
        let result = runGuard(
            arguments: ["--suspend", "--seconds", "5"],
            isRoot: true,
            signaling: signaling,
            nodes: FakeNodes([["rdisk0"]]),
            waiting: wait,
            output: recorder.output
        )

        #expect(result.exitCode == 30)
        #expect(wait.calls == 0, "it never idles believing it is protected")
        #expect(recorder.stderr.contains { $0.contains("Do NOT connect the disk") })
        #expect(signaling.sent.count == 1, "only the SIGSTOP; no resume")
        #expect(signaling.sent.first?.0 == .stop)
    }

    @Test("suspend resumes on interrupt when no new node appeared")
    func suspendResumesWhenNoNodeAppeared() {
        let recorder = GuardRecorder()
        let signaling = FakeProcessSignaling(pid: 42, states: ["T", "Ss"])
        let wait = FakeWait(interrupted: true)
        let result = runGuard(
            arguments: ["--suspend", "--seconds", "5"],
            isRoot: true,
            signaling: signaling,
            nodes: FakeNodes([["rdisk0"], ["rdisk0"]]),
            waiting: wait,
            output: recorder.output
        )

        #expect(result.exitCode == 0)
        #expect(wait.requestedSeconds == 5)
        #expect(signaling.sent.map(\.0) == [.stop, .cont])
        #expect(signaling.sent.allSatisfy { $0.1 == 42 })
        #expect(recorder.stderr.contains { $0.contains("diskarbitrationd resumed (pid 42") })
    }

    @Test("suspend holds the daemon when a new raw disk node is present")
    func suspendHoldsWhenANewNodeAppeared() {
        let recorder = GuardRecorder()
        let signaling = FakeProcessSignaling(pid: 42, states: ["T"])
        let result = runGuard(
            arguments: ["--suspend", "--seconds", "5"],
            isRoot: true,
            signaling: signaling,
            nodes: FakeNodes([["rdisk0"], ["rdisk0", "rdisk8", "rdisk8s1"]]),
            waiting: FakeWait(interrupted: true),
            output: recorder.output
        )

        #expect(result.exitCode == 0)
        #expect(signaling.sent.map(\.0) == [.stop], "no SIGCONT while the disk is attached")
        #expect(recorder.stderr.contains {
            $0.contains("stays SUSPENDED") && $0.contains("unplug the disk, then run: sudo kill -CONT 42")
        })
    }

    @Test("suspend warns about the system-wide hang and prints the manual resume command")
    func suspendPrintsTheWarningAndTheManualCommand() {
        let recorder = GuardRecorder()
        let signaling = FakeProcessSignaling(pid: 42, states: ["T", "Ss"])
        _ = runGuard(
            arguments: ["--suspend", "--seconds", "5"],
            isRoot: true,
            signaling: signaling,
            nodes: FakeNodes([["rdisk0"], ["rdisk0"]]),
            waiting: FakeWait(),
            output: recorder.output
        )

        #expect(recorder.stderr.first == "mode=suspend protection: NOT ACTIVE (diskarbitrationd not suspended yet)")
        #expect(recorder.stderr.contains { $0.contains("protection: ACTIVE") })
        #expect(recorder.stderr.contains { $0.contains("diskutil") && $0.contains("ioreg only") })
        #expect(recorder.stderr.contains { $0.contains("sudo kill -CONT 42") })
    }

    @Test("suspend --json summarises the teardown decision")
    func suspendJSONSummarisesTheTeardown() throws {
        let recorder = GuardRecorder()
        _ = runGuard(
            arguments: ["--suspend", "--seconds", "5", "--json"],
            isRoot: true,
            signaling: FakeProcessSignaling(pid: 42, states: ["T"]),
            nodes: FakeNodes([["rdisk0"], ["rdisk0", "rdisk8"]]),
            waiting: FakeWait(interrupted: true),
            output: recorder.output
        )

        let last = try #require(recorder.stdout.last)
        let summary = try #require(
            try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        )
        #expect(summary["event"] as? String == "summary")
        #expect(summary["mode"] as? String == "suspend")
        #expect(summary["protection"] as? String == "active")
        #expect(summary["diskarbitrationd_pid"] as? Int == 42)
        #expect(summary["teardown"] as? String == "held")
        #expect(summary["resumed"] as? Bool == false)
        #expect(summary["new_nodes"] as? [String] == ["rdisk8"])
    }
}

struct GuardArgumentTests {

    @Test("the documented flags parse")
    func parsesTheDocumentedFlags() {
        #expect(
            parseGuardArguments(["--suspend", "--seconds", "5", "--json"])
                == .options(GuardOptions(mode: .suspend, seconds: 5, json: true, observe: false))
        )
        #expect(
            parseGuardArguments(["--seconds=7"])
                == .options(GuardOptions(mode: .dissent, seconds: 7, json: false, observe: false))
        )
        #expect(
            parseGuardArguments(["--observe", "--seconds", "5"])
                == .options(GuardOptions(mode: .dissent, seconds: 5, json: false, observe: true))
        )
    }

    @Test("usage errors exit 2 and name the problem")
    func rejectsBadArguments() {
        let cases: [[String]] = [
            ["--seconds"],
            ["--seconds", "0"],
            ["--seconds", "-1"],
            ["--seconds", "soon"],
            ["--observe"],
            ["--observe", "--suspend", "--seconds", "5"],
            ["--wat"],
        ]
        for arguments in cases {
            let recorder = GuardRecorder()
            let result = runGuard(arguments: arguments, isRoot: true, output: recorder.output)
            #expect(result.exitCode == 2, "\(arguments) is a usage error")
            #expect(!result.stderr.isEmpty, "\(arguments) says why")
        }
    }

    @Test("--help exits 0 and documents the guard")
    func helpExitsZero() {
        let recorder = GuardRecorder()
        let result = runGuard(arguments: ["--help"], output: recorder.output)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("disktriage guard"))
    }
}
