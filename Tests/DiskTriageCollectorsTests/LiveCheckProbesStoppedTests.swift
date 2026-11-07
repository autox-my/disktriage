import Foundation
import Testing
import DiskTriageCore
@testable import DiskTriageCollectors

/// `check`'s filesystem-personality row used `diskutil listFilesystems`. While
/// DiskArbitration is stopped that call hangs, so the row must say
/// UNVERIFIABLE with the same reason the identity path uses.
struct LiveCheckProbesStoppedTests {

    @Test("REQ0168 a stopped daemon makes the filesystem row unverifiable, not hung")
    func REQ0168_filesystemRowIsUnverifiableWhenStopped() {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
        ])
        let probes = LiveCheckProbes(
            executor: executor,
            environment: [:]
        )

        let probe = probes.filesystemDrivers()

        #expect(probe == .unverifiable("diskarbitrationd stopped; diskutil skipped"))
        #expect(!executor.commands.contains(.diskutilListFilesystems),
                "diskutil was never invoked while it would hang")
    }

    @Test("REQ0168 the forced ioreg path also skips diskutil listFilesystems")
    func REQ0168_forcedPathSkipsListFilesystems() {
        let executor = RecordingExecutor([:])
        let probes = LiveCheckProbes(
            executor: executor,
            environment: ["DISKTRIAGE_FORCE_IOREG": "1"]
        )

        let probe = probes.filesystemDrivers()

        #expect(probe.status == .unverifiable)
        #expect(probe.detail.contains("DISKTRIAGE_FORCE_IOREG=1"))
        #expect(!executor.commands.contains(.diskutilListFilesystems))
    }

    // REQ-0174: DASessionCreate is a synchronous DiskArbitration call; with the
    // daemon SIGSTOPped it waits with no timeout, which is the measured
    // `disktriage check` hang. The row must not make the call at all.
    @Test("REQ0174 a stopped daemon makes the mount-guard row unverifiable, not hung")
    func REQ0174_REQ0176_mountGuardRowIsUnverifiableWhenStopped() {
        let executor = RecordingExecutor([
            .pgrepDiskArbitrationDaemon: .ok("155\n"),
            .processState(pid: 155): .ok("T\n"),
        ])
        let probes = LiveCheckProbes(executor: executor, environment: [:])

        let probe = probes.mountGuardAvailable()

        #expect(probe == .unverifiable("diskarbitrationd stopped; DASessionCreate skipped"))
        #expect(executor.commands == [.pgrepDiskArbitrationDaemon, .processState(pid: 155)],
                "only the stopped-daemon probe ran; no DiskArbitration session was created")
    }

    // REQ-0174: the whole table returns promptly while every diskutil or
    // DiskArbitration call would hang. This is the seam test for the measured
    // `check` run that did not return within 120 s with `guard --suspend`
    // active; it cannot be reproduced by stopping the daemon on a dev Mac.
    @Test("REQ0174 the whole check completes with no diskutil call while the daemon is stopped")
    func REQ0174_REQ0176_wholeCheckCompletesWithoutDiskutilWhileStopped() throws {
        let executor = HangingDaExecutor()
        let probes = LiveCheckProbes(
            executor: executor,
            environment: [:],
            versionRunner: executor
        )
        let started = Date()

        let report = CheckRunner(probes: probes).run()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 5, "check must return well under 20 s; took \(elapsed) s")
        #expect(executor.attemptedDiskutil.isEmpty,
                "no diskutil or DiskArbitration call was attempted: \(executor.attemptedDiskutil)")
        #expect(executor.attemptedDaemonCalls.count >= 2,
                "the daemon probe is what makes the skip possible")

        let filesystem = try #require(report.rows.first { $0.id == "filesystem-drivers" })
        #expect(filesystem.status == .unverifiable)
        #expect(filesystem.detail == "diskarbitrationd stopped; diskutil skipped")
        let guardRow = try #require(report.rows.first { $0.id == "mount-guard" })
        #expect(guardRow.status == .unverifiable)
        #expect(guardRow.detail == "diskarbitrationd stopped; DASessionCreate skipped")
        let raw = try #require(report.rows.first { $0.id == "raw-read" })
        #expect(raw.status == .unverifiable, "an undiscovered internal disk is not a grant")
        #expect(report.rows.count == 11)
    }

    // REQ-0175: the real run printed `missing ntfsls, ntfscat` while inspect
    // found ntfsls under the same prefix. The row now names the prefix and the
    // paths it searched instead of calling a found binary missing.
    @Test("REQ0175 the ntfs row names the prefix it searched when a tool is absent")
    func REQ0175_ntfsRowNamesThePrefixSearched() throws {
        let prefix = try temporaryPrefix(
            tools: ["ntfsinfo", "ntfscluster", "ntfscat"]
        )
        defer { try? FileManager.default.removeItem(atPath: prefix) }
        let executor = RecordingExecutor([
            .toolVersion(path: prefix + "/bin/ntfsinfo"): .ok("ntfsinfo v2026.9.28"),
            .toolVersion(path: prefix + "/bin/ntfscat"): .ok("ntfscat v2026.9.28"),
            .toolVersion(path: prefix + "/bin/ntfscluster"): .ok("ntfscluster v2026.9.28"),
        ])
        let probes = LiveCheckProbes(
            executor: executor,
            environment: ["DISKTRIAGE_NTFS_PREFIX": prefix],
            versionRunner: executor
        )

        let report = CheckRunner(probes: probes).run()
        let row = try #require(report.rows.first { $0.id == "ntfs-3g" })
        #expect(row.status == .fail)
        #expect(row.detail.contains("missing ntfsls"), "\(row.detail)")
        #expect(row.detail.contains(prefix), "the searched prefix is named: \(row.detail)")
        #expect(row.detail.contains("not found"), "\(row.detail)")
    }

    @Test("REQ0175 a found tool whose --version exits non-zero is present, not missing")
    func REQ0175_versionExitIsNotMissing() throws {
        let prefix = try temporaryPrefix(
            tools: ["ntfsinfo", "ntfsls", "ntfscat", "ntfscluster"]
        )
        defer { try? FileManager.default.removeItem(atPath: prefix) }
        let ntfsls = prefix + "/bin/ntfsls"
        let executor = RecordingExecutor([
            .toolVersion(path: ntfsls): CollectorResult(
                outcome: .error,
                exitCode: 1,
                stdout: "ntfsls v2026.9.28 (libntfs-3g) - Display information about an NTFS Volume.\n"
            ),
        ])
        let probes = LiveCheckProbes(
            executor: executor,
            environment: ["DISKTRIAGE_NTFS_PREFIX": prefix],
            versionRunner: executor
        )

        let probe = probes.tool(.ntfsls)
        #expect(probe.status == .pass, "\(probe.detail)")
        #expect(probe.detail.contains("ntfsls v2026.9.28"), "\(probe.detail)")
    }
}

// MARK: - Seams

/// Every diskutil shape is a hang; both DiskArbitration daemon probes answer
/// "stopped". Nothing in the live probes may reach the hanging shapes.
final class HangingDaExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var diskutil: [TriageCommand] = []
    private var daemon: [TriageCommand] = []

    var attemptedDiskutil: [TriageCommand] {
        lock.lock()
        defer { lock.unlock() }
        return diskutil
    }

    var attemptedDaemonCalls: [TriageCommand] {
        lock.lock()
        defer { lock.unlock() }
        return daemon
    }

    func run(_ command: TriageCommand) -> CollectorResult {
        lock.lock()
        switch command {
        case .diskutilList, .diskutilInfo, .diskutilListFilesystems:
            diskutil.append(command)
        default:
            break
        }
        if case .pgrepDiskArbitrationDaemon = command { daemon.append(command) }
        if case .processState = command { daemon.append(command) }
        lock.unlock()

        switch command {
        case .diskutilList, .diskutilInfo, .diskutilListFilesystems:
            // What the call does while diskarbitrationd is SIGSTOPped: no
            // answer, until a timeout that the old row did not have.
            return .timeout()
        case .pgrepDiskArbitrationDaemon:
            return .ok("155\n")
        case .processState:
            return .ok("T\n")
        case .ioregDeviceTree, .ioregMediaTree, .ioregUSBDeviceTree, .ioregStatistics, .ioregMedia:
            return .ok("")
        default:
            return .ok("1.0")
        }
    }

    func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult {
        run(command)
    }
}

func temporaryPrefix(tools: [String]) throws -> String {
    let prefix = FileManager.default.temporaryDirectory
        .appendingPathComponent("disktriage-prefix-\(UUID().uuidString)").path
    let bin = prefix + "/bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    for tool in tools {
        let path = bin + "/" + tool
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }
    return prefix
}
