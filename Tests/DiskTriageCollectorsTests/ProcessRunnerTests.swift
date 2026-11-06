import Foundation
import Testing
@testable import DiskTriageCollectors

/// Real-process tests for the collector framework (diskdoctor.md §2.7).
/// These run actual subprocesses; the commands are local test fixtures, not
/// triage commands, so they use the internal test-only policy.
struct ProcessRunnerTests {
    // REQ-0011: hard timeout and process-group kill.
    // REQ-0012: a timeout is an unresponsive-device signal, not a crash.
    @Test("a timeout is a result and kills the whole process group")
    func REQ0011_REQ0012_timeoutIsAResultAndKillsTheProcessGroup() throws {
        let marker = "disktriage-p1c-\(UUID().uuidString)"
        let dir = try makeTempDirectory()
        let sleepPath = dir.appendingPathComponent(marker).path
        // A symlink keeps `/bin/sleep`'s valid code signature while the unique
        // marker stays in the process command line for the survivor check.
        try FileManager.default.createSymbolicLink(atPath: sleepPath, withDestinationPath: "/bin/sleep")

        let runner = ProcessRunner(policy: .unrestrictedForTesting, timeout: 1.0, outputLimit: 64 * 1024)
        let started = Date()
        let result = runner.run(argv: ["/bin/sh", "-c", "\(sleepPath) 30 & wait"])
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.outcome == .timeout, "outcome")
        #expect(elapsed < 2.0, "returned within timeout + 1s, took \(elapsed)s")
        #expect(result.durationMs >= 900, "the timeout was actually waited out")

        try expectNoProcess(matching: marker, within: 2.0)
    }

    @Test("the child's exit code passes through")
    func exitCodePassesThrough() {
        let runner = ProcessRunner(policy: .unrestrictedForTesting, timeout: 5, outputLimit: 64 * 1024)

        let failing = runner.run(argv: ["/bin/sh", "-c", "exit 7"])
        #expect(failing.outcome == .error, "non-zero exit is not ok")
        #expect(failing.exitCode == 7, "exit code passthrough")

        let passing = runner.run(argv: ["/bin/sh", "-c", "printf hello; exit 0"])
        #expect(passing.outcome == .ok, "outcome")
        #expect(passing.exitCode == 0, "exitCode")
        #expect(passing.stdout == "hello", "stdout")
    }

    @Test("five megabytes of output is capped without deadlocking")
    func hugeOutputIsCappedWithoutDeadlock() {
        let runner = ProcessRunner(policy: .unrestrictedForTesting, timeout: 10, outputLimit: 4096)
        let started = Date()
        let result = runner.run(argv: ["/bin/sh", "-c", "/usr/bin/yes | /usr/bin/head -c 5242880"])
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.outcome == .ok, "outcome")
        #expect(result.stdout.utf8.count == 4096, "stdout capped at the configured limit")
        #expect(result.stdoutTruncated, "truncation is flagged")
        #expect(elapsed < 5.0, "the pipe was drained while the child ran, took \(elapsed)s")
    }

    @Test("a missing binary is notFound and a non-executable is denied")
    func spawnFailuresAreClassified() throws {
        let runner = ProcessRunner(policy: .unrestrictedForTesting, timeout: 5, outputLimit: 4096)

        let missing = runner.run(argv: ["/nonexistent/disktriage-p1c-probe"])
        #expect(missing.outcome == .notFound, "missing binary")
        #expect(missing.exitCode == nil, "no exit status was produced")

        let dir = try makeTempDirectory()
        let script = dir.appendingPathComponent("not-executable.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)

        let denied = runner.run(argv: [script.path])
        #expect(denied.outcome == .denied, "non-executable binary")
    }

    @Test("the environment is explicit and sanitised")
    func environmentIsSanitised() {
        let runner = ProcessRunner(policy: .unrestrictedForTesting, timeout: 5, outputLimit: 4096)
        let result = runner.run(argv: ["/usr/bin/env"])

        #expect(result.outcome == .ok, "outcome")
        let lines = Set(result.stdout.split(separator: "\n").map(String.init))
        #expect(lines == [
            "LC_ALL=C",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ], "only the explicit environment is inherited: \(lines)")
    }

    // REQ-0013 / REQ-0014: the policy is enforced inside the runner, so a
    // forbidden argv never reaches exec.
    @Test("a policy-rejected command never executes")
    func policyIsCheckedBeforeExec() throws {
        let dir = try makeTempDirectory()
        let marker = dir.appendingPathComponent("executed")
        let script = dir.appendingPathComponent("would-touch")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = ProcessRunner() // the real triage policy
        let result = runner.run(argv: [script.path, "-t", "short", "/dev/disk0"])

        #expect(result.outcome == .policyRejected, "outcome")
        #expect(result.policyViolation == .notAllowListed, "violation")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the binary must not have run")
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("disktriage-p1c-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Fails unless `pgrep -f <marker>` finds nothing within `within` seconds.
private func expectNoProcess(matching marker: String, within: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(within)
    while Date() < deadline {
        if !processExists(matching: marker) { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    Issue.record("a process matching \(marker) survived the process-group kill")
}

private func processExists(matching marker: String) -> Bool {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    probe.arguments = ["-f", marker]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do {
        try probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    } catch {
        return false
    }
}
