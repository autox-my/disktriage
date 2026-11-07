import Foundation
import Testing
import DiskTriageTestSupport
@testable import DiskTriageCollectors

/// The inspect-side additions: an argv shape per tool (never a write flag,
/// never a device node), the tool locator, and the runner that builds them.
struct NTFSToolsTests {
    private let temp = TempDir()


    private let policy = CommandPolicy.inspect

    // REQ-0114: the only shapes inspect may run are the read-only ntfsinfo and
    // ntfsls forms, on an absolute image path.
    @Test("REQ0114 the inspect policy allows only ntfsinfo -m and ntfsls -l/-R")
    func REQ0114_allowsOnlyReadOnlyShapes() {
        let allowed: [[String]] = [
            ["/opt/ntfs/bin/ntfsinfo", "-m", "/images/plain.img"],
            ["/Users/fd/ntfs/bin/ntfsls", "-l", "/images/plain.img"],
            ["/Users/fd/ntfs/bin/ntfsls", "-R", "/images/plain.img"],
            ["/Users/fd/ntfs/bin/ntfsls", "-l", "-R", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfscat", "/images/plain.img", "/docs/notes.md"],
            ["/opt/ntfs/bin/ntfscluster", "-c", "0-16382", "-v", "/images/plain.img"],
        ]
        for argv in allowed {
            #expect(policy.evaluate(argv) == .allowed, "expected allowed: \(argv)")
        }
    }

    @Test("REQ0089_REQ0098_REQ0114 write flags, ntfsfix, mount paths and relative tools are rejected")
    func REQ0089_REQ0098_REQ0114_rejectsEverythingElse() {
        let rejected: [[String]] = [
            [],
            ["/opt/ntfs/bin/ntfsfix", "-n", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsinfo", "-m"],
            ["/opt/ntfs/bin/ntfsinfo", "-m", "/images/plain.img", "-f"],
            ["/opt/ntfs/bin/ntfsinfo", "-f", "-m", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsls", "-lR", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsls", "-i", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsinfo", "-m", "/dev/disk4"],
            ["ntfsinfo", "-m", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfsinfo", "-m", "relative.img"],
            // ntfscat: the volume path may not escape.
            ["/opt/ntfs/bin/ntfscat", "/images/plain.img", "/docs/../etc/passwd"],
            ["/opt/ntfs/bin/ntfscat", "/images/plain.img", "/docs//notes.md"],
            ["/opt/ntfs/bin/ntfscat", "/images/plain.img", "-"],
            ["/opt/ntfs/bin/ntfscat", "/dev/rdisk4", "/docs/notes.md"],
            // ntfscluster: one numeric range, -v, no force or other flags.
            ["/opt/ntfs/bin/ntfscluster", "-c", "0-1,4-5", "-v", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfscluster", "-c", "9-1", "-v", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfscluster", "-f", "-c", "0-1", "/images/plain.img"],
            ["/opt/ntfs/bin/ntfscluster", "-c", "0-1", "/images/plain.img"],
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

    // REQ-0251: the policy's allow-list is the tool basename plus an absolute
    // path, so a located libexec path is allowed while the same directory's
    // other binaries are not. There is deliberately no prefix wildcard.
    @Test("REQ0251 the inspect policy accepts a located libexec tool and rejects its neighbours")
    func REQ0251_libexecPathIsAllowListed() {
        let libexec = "/opt/homebrew/Cellar/disktriage/0.1.0/libexec/ntfs-3g"
        let allowed: [[String]] = [
            [libexec + "/bin/ntfsinfo", "-m", "/images/plain.img"],
            [libexec + "/bin/ntfsls", "-R", "/images/plain.img"],
            [libexec + "/sbin/ntfscat", "/images/plain.img", "/docs/notes.md"],
            [libexec + "/sbin/ntfscluster", "-c", "0-16382", "-v", "/images/plain.img"],
        ]
        for argv in allowed {
            #expect(policy.evaluate(argv) == .allowed, "expected allowed: \(argv)")
        }
        let rejected: [[String]] = [
            [libexec + "/bin/ntfsfix", "-n", "/images/plain.img"],
            [libexec + "/bin/ntfsinfo", "-m", "plain.img"],
            [libexec + "/bin/ntfsinfo", "-m", "/dev/disk4"],
        ]
        for argv in rejected {
            #expect(policy.evaluate(argv) != .allowed, "expected rejected: \(argv)")
        }
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

    // REQ-0249: a Homebrew keg is reached through the symlink brew puts in
    // bin/, so the executable path is resolved before its ../libexec is used.
    // The order is prefix, installed libexec, PATH — never PATH first, because
    // sudo strips the environment that carries the prefix.
    @Test("REQ0249 the locator searches the executable's libexec after the prefix and before PATH")
    func REQ0249_executableRelativeLibexecOrder() throws {
        let keg = temp.child("Cellar/disktriage/0.1.0")
        let libexec = keg + "/libexec/ntfs-3g"
        try writeExecutable(libexec + "/bin/ntfsinfo")
        try writeExecutable(libexec + "/bin/ntfsls")
        try writeExecutable(libexec + "/sbin/mkntfs")
        try writeExecutable(keg + "/bin/disktriage")

        let link = temp.child("bin/disktriage")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: temp.child("bin")),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: keg + "/bin/disktriage"
        )

        let pathTools = temp.child("path-tools")
        try writeExecutable(pathTools + "/ntfsinfo")
        try writeExecutable(pathTools + "/ntfsls")

        let prefix = try makePrefix(tools: ["ntfsinfo", "ntfsls"], sbinTools: [])

        // 1. The explicit prefix outranks the installed tree.
        let prefixed = try #require(NTFSToolLocator.locate(
            environment: ["DISKTRIAGE_NTFS_PREFIX": prefix, "PATH": pathTools],
            executablePath: link
        ))
        #expect(prefixed.ntfsinfo == prefix + "/bin/ntfsinfo")

        // 2. Without the prefix, the resolved keg's libexec outranks PATH.
        let installed = try #require(NTFSToolLocator.locate(
            environment: ["PATH": pathTools],
            executablePath: link
        ))
        #expect(installed.ntfsinfo == canonical(libexec + "/bin/ntfsinfo"))
        #expect(installed.ntfsls == canonical(libexec + "/bin/ntfsls"))
        #expect(NTFSToolLocator.resolve(
            "mkntfs",
            environment: ["PATH": ""],
            executablePath: link
        ) == canonical(libexec + "/sbin/mkntfs"))

        // 3. It still works with a stripped PATH (the sudo case).
        let stripped = try #require(NTFSToolLocator.locate(
            environment: ["PATH": ""],
            executablePath: link
        ))
        #expect(stripped.ntfsinfo == canonical(libexec + "/bin/ntfsinfo"))
    }

    // REQ-0250: `check` must not answer UNVERIFIABLE for a Homebrew install:
    // the row resolves the same installed libexec the locator does, and names
    // it in the detail.
    @Test("REQ0250 check reports ntfs-3g found in the installed libexec beside the executable")
    func REQ0250_selfTestFindsInstalledLibexec() throws {
        let keg = temp.child("Cellar/disktriage/0.1.0")
        let libexec = keg + "/libexec/ntfs-3g"
        let tools = ["ntfsinfo", "ntfsls", "ntfscat", "ntfscluster"]
        for tool in tools {
            try writeExecutable(libexec + "/bin/\(tool)")
        }
        try writeExecutable(keg + "/bin/disktriage")
        let link = temp.child("bin/disktriage")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: temp.child("bin")),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: keg + "/bin/disktriage"
        )

        let executor = RecordingExecutor(Dictionary(
            uniqueKeysWithValues: tools.map { tool in
                (.toolVersion(path: libexec + "/bin/\(tool)"), .ok("\(tool) v2026.9.28"))
            }
        ))
        let probes = LiveCheckProbes(
            executor: executor,
            environment: ["PATH": "", "DISKTRIAGE_NTFS_PREFIX": ""],
            versionRunner: executor,
            executablePath: link
        )

        let report = CheckRunner(probes: probes).run()
        let row = try #require(report.rows.first { $0.id == "ntfs-3g" })
        #expect(row.status == .pass, "\(row.detail)")
        #expect(row.detail.contains(canonical(libexec)), "the installed location is named: \(row.detail)")
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

    @Test("the copy runner builds the one-pass map, the file read and the tall listing")
    func copyRunnerBuildsItsArgv() {
        let executor = RecordingExecutor([:])
        let runner = NTFSCopyToolRunner(
            toolchain: NTFSCopyToolchain(
                ntfsinfo: "/opt/ntfs/bin/ntfsinfo",
                ntfsls: "/opt/ntfs/bin/ntfsls",
                ntfscat: "/opt/ntfs/bin/ntfscat",
                ntfscluster: "/opt/ntfs/bin/ntfscluster"
            ),
            executor: executor
        )

        _ = runner.volumeInfo(image: "/images/plain.img")
        _ = runner.listing(image: "/images/plain.img")
        _ = runner.catFile(image: "/images/plain.img", path: "/docs/notes.md")
        _ = runner.clusterRuns(image: "/images/plain.img", lastCluster: 16_382)

        #expect(executor.commands == [
            .ntfsTool(path: "/opt/ntfs/bin/ntfsinfo", arguments: ["-m", "/images/plain.img"]),
            .ntfsTool(path: "/opt/ntfs/bin/ntfsls", arguments: ["-l", "-R", "/images/plain.img"]),
            .ntfsTool(path: "/opt/ntfs/bin/ntfscat", arguments: ["/images/plain.img", "/docs/notes.md"]),
            .ntfsTool(
                path: "/opt/ntfs/bin/ntfscluster",
                arguments: ["-c", "0-16382", "-v", "/images/plain.img"]
            ),
        ])
        #expect(executor.requestedTimeouts == [30, 120, 120, 120])
    }

    @Test("the copy locator requires all four tools")
    func copyLocatorRequiresAllFour() throws {
        let three = try makePrefix(tools: ["ntfsinfo", "ntfsls", "ntfscat"], sbinTools: [])
        #expect(NTFSCopyToolLocator.locate(environment: ["DISKTRIAGE_NTFS_PREFIX": three]) == nil)

        let four = try makePrefix(
            tools: ["ntfsinfo", "ntfsls", "ntfscat", "ntfscluster"],
            sbinTools: []
        )
        let chain = try #require(NTFSCopyToolLocator.locate(environment: ["DISKTRIAGE_NTFS_PREFIX": four]))
        #expect(chain.ntfscat == four + "/bin/ntfscat")
        #expect(chain.ntfscluster == four + "/bin/ntfscluster")
    }

    // MARK: - Support

    private func makePrefix(tools: [String], sbinTools: [String]) throws -> String {
        let prefix = URL(fileURLWithPath: temp.child("prefix-\(UUID().uuidString)"))
        for tool in tools {
            try writeExecutable(prefix.appendingPathComponent("bin/\(tool)"))
        }
        for tool in sbinTools {
            try writeExecutable(prefix.appendingPathComponent("sbin/\(tool)"))
        }
        return prefix.path
    }

    private func writeExecutable(_ path: String) throws {
        try writeExecutable(URL(fileURLWithPath: path))
    }

    /// The locator resolves symlinks, which on macOS also resolves the
    /// `/var` -> `/private/var` temp root. Expectations compare the same way.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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
