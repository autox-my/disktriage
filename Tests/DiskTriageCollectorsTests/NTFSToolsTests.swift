import Foundation
import Testing
@testable import DiskTriageCollectors

/// The inspect-side additions: an argv shape per tool (never a write flag,
/// never a device node), the tool locator, and the runner that builds them.
struct NTFSToolsTests {

    private let policy = CommandPolicy.inspect

    // REQ-0114: the only shapes inspect may run are the read-only ntfsinfo and
    // ntfsls forms, on an absolute image path.
    @Test("REQ0114 the inspect policy allows only ntfsinfo -m and ntfsls -l/-R")
    func REQ0114_allowsOnlyReadOnlyShapes() {
        let allowed: [[String]] = [
            ["/opt/ntfs/bin/ntfsinfo", "-m", "/images/plain.img"],
            ["/Users/fd/ntfs/bin/ntfsls", "-l", "/images/plain.img"],
            ["/Users/fd/ntfs/bin/ntfsls", "-R", "/images/plain.img"],
        ]
        for argv in allowed {
            #expect(policy.evaluate(argv) == .allowed, "expected allowed: \(argv)")
        }
    }

    @Test("REQ0114 write flags, ntfsfix, mount paths and relative tools are rejected")
    func REQ0114_rejectsEverythingElse() {
        let rejected: [[String]] = [
            [],
            ["/opt/ntfs/bin/ntfsfix", "-n", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfscat", "/images/plain.img", "/readme.txt"],
            ["/opt/ntfs/bin/ntfsinfo", "-m"],
            ["/opt/ntfs/bin/ntfsinfo", "-m", "/images/plain.img", "-f"],
            ["/opt/ntfs/bin/ntfsinfo", "-f", "-m", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsls", "-lR", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsls", "-i", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsinfo", "-m", "/dev/disk4"],
            ["ntfsinfo", "-m", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsinfo", "-m", "relative.img"],
        ]
        for argv in rejected {
            #expect(policy.evaluate(argv) != .allowed, "expected rejected: \(argv)")
        }
    }

    // `--version` is a check command, never an inspect one.
    @Test("the check policy still allows versions and inspect does not")
    func checkAndInspectStaySeparate() {
        let version = ["/opt/ntfs/bin/ntfsinfo", "--version"]
        #expect(CommandPolicy.check.evaluate(version) == .allowed)
        #expect(policy.evaluate(version) != .allowed)
    }

    @Test("the locator finds the tools through DISKTRIAGE_NTFS_PREFIX bin and sbin")
    func locatesThroughThePrefix() throws {
        let prefix = try makePrefix(tools: ["ntfsinfo", "ntfsls"], sbinTools: ["mkntfs"])
        let chain = try #require(NTFSToolLocator.locate(environment: ["DISKTRIAGE_NTFS_PREFIX": prefix]))

        #expect(chain.ntfsinfo == prefix + "/bin/ntfsinfo")
        #expect(chain.ntfsls == prefix + "/bin/ntfsls")
        #expect(NTFSToolLocator.resolve("mkntfs", environment: ["DISKTRIAGE_NTFS_PREFIX": prefix])
            == prefix + "/sbin/mkntfs")
    }

    @Test("a locator with no prefix and an empty PATH finds nothing")
    func missingToolsAreNil() {
        #expect(NTFSToolLocator.locate(environment: ["PATH": "", "DISKTRIAGE_NTFS_PREFIX": ""]) == nil)
    }

    @Test("the runner issues the exact read-only argv and its own timeouts")
    func runnerBuildsTheArgv() {
        let executor = RecordingExecutor([:])
        let runner = NTFSToolRunner(
            toolchain: NTFSToolchain(ntfsinfo: "/opt/ntfs/bin/ntfsinfo", ntfsls: "/opt/ntfs/bin/ntfsls"),
            executor: executor
        )

        _ = runner.volumeInfo(image: "/images/plain.img")
        _ = runner.listing(image: "/images/plain.img", recursive: false)
        _ = runner.listing(image: "/images/plain.img", recursive: true)

        #expect(executor.commands == [
            .ntfsTool(path: "/opt/ntfs/bin/ntfsinfo", arguments: ["-m", "/images/plain.img"]),
            .ntfsTool(path: "/opt/ntfs/bin/ntfsls", arguments: ["-l", "/images/plain.img"]),
            .ntfsTool(path: "/opt/ntfs/bin/ntfsls", arguments: ["-R", "/images/plain.img"]),
        ])
        #expect(executor.requestedTimeouts == [30, 30, 120])
    }

    // MARK: - Support

    private func makePrefix(tools: [String], sbinTools: [String]) throws -> String {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("disktriage-ntfs-\(UUID().uuidString)")
        for tool in tools {
            try writeExecutable(prefix.appendingPathComponent("bin/\(tool)"))
        }
        for tool in sbinTools {
            try writeExecutable(prefix.appendingPathComponent("sbin/\(tool)"))
        }
        return prefix.path
    }

    private func writeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
