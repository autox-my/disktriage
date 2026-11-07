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
}
