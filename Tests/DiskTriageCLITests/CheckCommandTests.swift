import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors
import DiskTriageCLI

/// P2b: `disktriage check` through its own seam. All probes are injected, so
/// no test opens a device, a subprocess or the live filesystem.
struct CheckCommandTests {

    @Test("all rows PASS prints the human table and exits 0")
    func allPassExitsZero() {
        let probes = CLICheckProbes(raw: [.read(bytes: 4096), .read(bytes: 4096)])
        let result = runCheck(arguments: [], probes: probes)

        #expect(result.exitCode == 0, "all checks pass")
        #expect(result.stdout.contains("raw device read"), "the raw read row")
        #expect(result.stdout.contains("VERIFIED"), "two successes")
        #expect(result.stdout.contains("VERDICT  PASS"), "the verdict line")
        #expect(result.stderr.isEmpty, "nothing on stderr")
    }

    // REQ-0061: a denied probe is a definite finding, and the onboarding names
    // the terminal and the exact deep link.
    // REQ-0067, REQ-0068: the terminal and the broad grant.
    @Test("REQ0061_REQ0067_REQ0068 DENIED exits 1 and prints the grant instructions")
    func REQ0061_REQ0067_REQ0068_deniedExitsOne() {
        let probes = CLICheckProbes(raw: [.failed(errno: 1, message: "Operation not permitted")])
        let result = runCheck(arguments: [], probes: probes)

        #expect(result.exitCode == 1, "a definite TCC denial")
        #expect(result.stdout.contains("DENIED"), "the state")
        #expect(result.stdout.contains("Ghostty"), "the responsible terminal")
        #expect(result.stdout.contains("broad grant"), "the warning")
        #expect(result.stdout.contains(FDAGuidance.fullDiskAccessDeepLink), "the deep link")
        #expect(result.stdout.contains("next run"), "re-probing is stated")
    }

    @Test("an UNKNOWN probe exits 3, never 0")
    func unknownExitsThree() {
        let probes = CLICheckProbes(raw: [.notRun(reason: "no internal disk found")])
        let result = runCheck(arguments: [], probes: probes)

        #expect(result.exitCode == 3, "UNVERIFIABLE")
        #expect(result.stdout.contains("VERDICT  UNVERIFIABLE"), "the verdict line")
        #expect(!result.stdout.contains("VERDICT  PASS"), "never a pass")
    }

    @Test("REQ0056 --json carries the same verdict and every row")
    func REQ0056_jsonCarriesTheVerdict() throws {
        let probes = CLICheckProbes(raw: [.notRun(reason: "no internal disk found")])
        let result = runCheck(arguments: ["--json"], probes: probes)

        #expect(result.exitCode == 3, "same code as the table")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["exit_code"] as? Int == 3, "exit_code")
        #expect(object["verdict"] as? String == "UNVERIFIABLE", "verdict")
        let checks = try #require(object["checks"] as? [[String: Any]], "checks")
        #expect(checks.count == 11, "every self-test row")
        #expect(checks.contains { $0["id"] as? String == "ntfs-3g" }, "the ntfs row")
    }

    // REQ-0062: nothing is cached across runs.
    @Test("REQ0062 a denied run followed by a granted run is re-probed")
    func REQ0062_runsAreReProbed() {
        let probes = CLICheckProbes(raw: [
            .failed(errno: 1, message: "Operation not permitted"),
            .read(bytes: 4096),
        ])

        let denied = runCheck(arguments: [], probes: probes)
        #expect(denied.exitCode == 1, "the first run is denied")

        let granted = runCheck(arguments: [], probes: probes)
        #expect(granted.exitCode == 0, "the second run sees the new grant")
        #expect(granted.stdout.contains("VERIFIED"), "the second probe ran")
    }

    @Test("check --help exits 0 and never probes")
    func helpExitsZeroWithoutProbing() {
        let probes = CLICheckProbes(raw: [.failed(errno: 1, message: "unused")])
        let result = runCheck(arguments: ["--help"], probes: probes)

        #expect(result.exitCode == 0, "help")
        #expect(result.stdout.contains("usage: disktriage check"), "the usage line")
        #expect(probes.rawCalls == 0, "help does no work")
    }

    @Test("an unknown option is a usage error, not a verdict")
    func unknownOptionIsUsage() {
        let probes = CLICheckProbes(raw: [.read(bytes: 4096)])
        let result = runCheck(arguments: ["--wat"], probes: probes)

        #expect(result.exitCode == 2, "the CLI's usage code")
        #expect(result.stdout.isEmpty, "no table")
        #expect(result.stderr.contains("--wat"), "names the option")
        #expect(probes.rawCalls == 0, "usage errors do not probe")
    }
}

// MARK: - Scripted probes

private final class CLICheckProbes: CheckProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var rawScript: [FDAProbeEvidence]
    private var rawIndex = 0
    private var rawCount = 0

    init(raw: [FDAProbeEvidence]) {
        self.rawScript = raw
    }

    var rawCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return rawCount
    }

    func runningAsRoot() -> Bool { false }

    func probeRawDevice() -> FDAProbeEvidence {
        lock.lock(); defer { lock.unlock() }
        rawCount += 1
        guard !rawScript.isEmpty else { return .notRun(reason: "not scripted") }
        let evidence = rawScript[min(rawIndex, rawScript.count - 1)]
        rawIndex += 1
        return evidence
    }

    func removableVolumeAccess() -> CheckProbe { .pass("/Volumes lists 2 entries") }
    func tool(_ tool: CheckTool) -> CheckProbe {
        tool == .smartctl || tool == .ddrescue
            ? .pass("\(tool.rawValue) 1.0")
            : .pass("\(tool.rawValue) 2022.10.3")
    }
    func filesystemDrivers() -> CheckProbe { .pass("iboysoft_NTFS.fs") }
    func unifiedLogReadable() -> CheckProbe { .pass("readable") }
    func mountGuardAvailable() -> CheckProbe { .pass("DASession created") }
    func sleepPrevention() -> CheckProbe { .pass("/usr/bin/caffeinate") }
    func diskArbitrationDaemon() -> CheckProbe { .pass("running") }
    func terminal() -> TerminalIdentity {
        TerminalIdentity(name: "Ghostty", bundlePath: "/Applications/Ghostty.app")
    }
}
