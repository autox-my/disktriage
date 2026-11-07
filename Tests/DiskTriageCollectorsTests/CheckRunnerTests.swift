import Foundation
import Testing
import DiskTriageCore
@testable import DiskTriageCollectors

/// P2b: every probe is injected here; nothing in this file touches a device.
struct CheckRunnerTests {

    @Test("all rows PASS is exit 0, and a successful probe is run twice to VERIFY")
    func allPassingProbesExitZero() throws {
        let probes = ScriptedCheckProbes(raw: [.read(bytes: 4096), .read(bytes: 4096)])
        let report = CheckRunner(probes: probes).run()

        #expect(report.exitCode == 0, "everything passed")
        #expect(report.rows.count == 11, "all self-test rows are present")
        let raw = try #require(report.rows.first { $0.id == "raw-read" })
        #expect(raw.status == .pass, "a successful read passes")
        #expect(raw.detail.contains("VERIFIED"), "two successes verify")
        #expect(probes.rawCalls == 2, "a second probe in the same run")
    }

    // REQ-0061: a real probe every run.
    // REQ-0062: no result is cached across runs.
    @Test("REQ0061_REQ0062 EPERM fails one run and the next run re-probes instead of caching")
    func REQ0061_REQ0062_deniedRunIsNotCached() {
        let probes = ScriptedCheckProbes(raw: [
            .failed(errno: 1, message: "Operation not permitted"),
            .read(bytes: 4096),
        ])

        let first = CheckRunner(probes: probes).run()
        #expect(first.exitCode == 1, "a TCC denial is a definite finding")
        #expect(probes.rawCalls == 1, "the denied run probed once")

        let second = CheckRunner(probes: probes).run()
        #expect(second.exitCode == 0, "the next run observes the grant, not a cache")
        #expect(probes.rawCalls == 3, "one probe on each run, plus the verifying probe")
        let raw = second.rows.first { $0.id == "raw-read" }
        #expect(raw?.detail.contains("VERIFIED") == true, "the fresh probe is believed")
    }

    // REQ-0067: the terminal is named.
    // REQ-0068: the grant is called broad.
    @Test("REQ0067_REQ0068 a DENIED row names Ghostty, the broad grant, the deep link and the relaunch")
    func REQ0067_REQ0068_deniedRowCarriesTheOnboarding() throws {
        let probes = ScriptedCheckProbes(raw: [.failed(errno: 1, message: "Operation not permitted")])
        let report = CheckRunner(probes: probes).run()

        let raw = try #require(report.rows.first { $0.id == "raw-read" })
        #expect(raw.status == .fail, "TCC denied")
        #expect(raw.detail.contains("DENIED"), "the state is in the table")
        let guidance = (raw.guidance ?? []).joined(separator: "\n")
        #expect(guidance.contains("Ghostty"), "names the responsible process")
        #expect(guidance.contains("/Applications/Ghostty.app"), "names the exact bundle")
        #expect(guidance.lowercased().contains("broad grant"), "warns it is broad")
        #expect(guidance.contains(FDAGuidance.fullDiskAccessDeepLink), "the deep link")
        #expect(guidance.contains("relaunch"), "relaunch required")
        #expect(guidance.contains("next run"), "re-probes next run")
    }

    @Test("EACCES is PASS with a sudo note, not a failure")
    func eaccesPassesWithTheSudoNote() {
        let probes = ScriptedCheckProbes(raw: [.failed(errno: 13, message: "Permission denied")])
        let report = CheckRunner(probes: probes).run()

        let raw = report.rows.first { $0.id == "raw-read" }
        #expect(raw?.status == .pass, "TCC passed")
        #expect(raw?.detail.contains("sudo") == true, "names the Unix remedy")
        #expect(report.exitCode == 0, "not reported as a failure")
    }

    @Test("an unknown probe is UNVERIFIABLE, so the report exits 3")
    func unknownProbeIsUnverifiable() {
        let probes = ScriptedCheckProbes(raw: [.failed(errno: 6, message: "Device not configured")])
        let report = CheckRunner(probes: probes).run()

        #expect(report.exitCode == 3, "cannot be told")
        let raw = report.rows.first { $0.id == "raw-read" }
        #expect(raw?.status == .unverifiable, "UNVERIFIABLE, never PASS")
        #expect(raw?.guidance?.isEmpty == false, "the onboarding still tells the user what to grant")
    }

    @Test("a probe that never ran is UNVERIFIABLE, never GRANTED")
    func notRunIsUnverifiable() {
        let probes = ScriptedCheckProbes(raw: [.notRun(reason: "no internal disk found")])
        let report = CheckRunner(probes: probes).run()

        let raw = report.rows.first { $0.id == "raw-read" }
        #expect(raw?.status == .unverifiable, "absent evidence is not a grant")
        #expect(raw?.detail.contains("no internal disk found") == true, "the reason is kept")
    }

    // REQ-0006: the third-party drivers are listed, never installed.
    // REQ-0069: root, raw access, removable volumes, the unified log, the mount
    // guard and the driver inventory are all reported.
    // REQ-0070: smartctl and ddrescue are reported with their versions.
    @Test("REQ0006_REQ0069_REQ0070 every self-test row is present and the tools carry versions")
    func REQ0006_REQ0069_REQ0070_reportsEveryRowAndToolVersion() throws {
        let probes = ScriptedCheckProbes(raw: [.read(bytes: 4096), .read(bytes: 4096)])
        probes.rootValue = true
        probes.drivers = .pass("iboysoft_NTFS (/Library/Filesystems/iboysoft_NTFS.fs)")
        let report = CheckRunner(probes: probes).run()

        let ids = Set(report.rows.map(\.id))
        for id in ["root", "raw-read", "removable-volume", "unified-log",
                   "mount-guard", "filesystem-drivers"] {
            #expect(ids.contains(id), "row \(id) is reported")
        }

        let root = try #require(report.rows.first { $0.id == "root" })
        #expect(root.status == .pass, "root status")
        let drivers = try #require(report.rows.first { $0.id == "filesystem-drivers" })
        #expect(drivers.detail.contains("iboysoft_NTFS"), "the installed driver is named")
        #expect(drivers.status == .pass, "the inventory is readable")

        let smart = try #require(report.rows.first { $0.id == "smartctl" })
        #expect(smart.status == .pass, "smartctl is present")
        #expect(smart.detail.contains("smartctl 7.5"), "the version is shown")
        let ddrescue = try #require(report.rows.first { $0.id == "ddrescue" })
        #expect(ddrescue.status == .pass, "ddrescue is present")
        #expect(ddrescue.detail.contains("GNU ddrescue 1.30"), "the version is shown")
    }

    @Test("a partial ntfs-3g set is FAIL; a missing set is UNVERIFIABLE")
    func ntfsToolsAreThreeState() {
        let partial = ScriptedCheckProbes(raw: [.read(bytes: 4096)])
        partial.toolProbes[.ntfsinfo] = .pass("ntfsinfo 2022.10.3")
        for tool in [CheckTool.ntfsls, .ntfscat, .ntfscluster] {
            partial.toolProbes[tool] = .unverifiable("not found")
        }
        let partialReport = CheckRunner(probes: partial).run()
        #expect(partialReport.rows.first { $0.id == "ntfs-3g" }?.status == .fail,
                "a partial install is a definite finding")

        let missing = ScriptedCheckProbes(raw: [.read(bytes: 4096)])
        for tool in [CheckTool.ntfsinfo, .ntfsls, .ntfscat, .ntfscluster] {
            missing.toolProbes[tool] = .unverifiable("not found")
        }
        let missingReport = CheckRunner(probes: missing).run()
        #expect(missingReport.rows.first { $0.id == "ntfs-3g" }?.status == .unverifiable,
                "not installed is not a failure")
    }
}

// MARK: - Scripted probes

/// Every value is supplied by the test: no subprocess, no filesystem and no
/// device read.
final class ScriptedCheckProbes: CheckProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var rawScript: [FDAProbeEvidence]
    private var rawIndex = 0
    private var rawCount = 0

    var rootValue = false
    var removable = CheckProbe.pass("/Volumes lists 2 entries")
    var toolProbes: [CheckTool: CheckProbe] = [
        .smartctl: .pass("smartctl 7.5 2025-04-30"),
        .ddrescue: .pass("GNU ddrescue 1.30"),
        .ntfsinfo: .pass("ntfsinfo 2022.10.3"),
        .ntfsls: .pass("ntfsls 2022.10.3"),
        .ntfscat: .pass("ntfscat 2022.10.3"),
        .ntfscluster: .pass("ntfscluster 2022.10.3"),
    ]
    var drivers = CheckProbe.pass("iboysoft_NTFS (/Library/Filesystems/iboysoft_NTFS.fs)")
    var log = CheckProbe.pass("readable")
    var guardAvailable = CheckProbe.pass("DASession created")
    var sleep = CheckProbe.pass("/usr/bin/caffeinate")
    var daemon = CheckProbe.pass("running")
    var terminalIdentity = TerminalIdentity(
        name: "Ghostty",
        bundlePath: "/Applications/Ghostty.app"
    )

    init(raw: [FDAProbeEvidence]) {
        self.rawScript = raw
    }

    var rawCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return rawCount
    }

    func runningAsRoot() -> Bool { rootValue }

    func probeRawDevice() -> FDAProbeEvidence {
        lock.lock()
        defer { lock.unlock() }
        rawCount += 1
        guard !rawScript.isEmpty else { return .notRun(reason: "the test supplied no probe") }
        let evidence = rawScript[min(rawIndex, rawScript.count - 1)]
        rawIndex += 1
        return evidence
    }

    func removableVolumeAccess() -> CheckProbe { removable }
    func tool(_ tool: CheckTool) -> CheckProbe { toolProbes[tool] ?? .unverifiable("no script") }
    func filesystemDrivers() -> CheckProbe { drivers }
    func unifiedLogReadable() -> CheckProbe { log }
    func mountGuardAvailable() -> CheckProbe { guardAvailable }
    func sleepPrevention() -> CheckProbe { sleep }
    func diskArbitrationDaemon() -> CheckProbe { daemon }
    func terminal() -> TerminalIdentity { terminalIdentity }
}
