import Foundation
import Darwin

/// The live process seam: `pgrep`, `ps -o stat=` and `kill(2)`.
///
/// It only ever sends a signal to the pid returned by
/// `diskArbitrationDaemonPid()`; `send` refuses pid 0 and 1 as a last guard.
/// Nothing here runs in the test suite — the tests inject a fake, because a
/// stray SIGSTOP would stop diskarbitrationd system-wide.
public struct LiveProcessSignaling: ProcessSignaling {
    public init() {}

    public func diskArbitrationDaemonPid() -> Int32? {
        guard let output = run("/usr/bin/pgrep", ["-x", "diskarbitrationd"]) else {
            return nil
        }
        return output.split(whereSeparator: \.isNewline).first.flatMap { Int32($0) }
    }

    public func send(_ signal: GuardSignal, to pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        let number: Int32 = signal == .stop ? SIGSTOP : SIGCONT
        return Darwin.kill(pid, number) == 0
    }

    public func state(of pid: Int32) -> String? {
        guard let output = run("/bin/ps", ["-o", "stat=", "-p", String(pid)]) else {
            return nil
        }
        let state = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty ? nil : state
    }

    private func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: ps/pgrep output is tiny, and reading first
        // cannot deadlock on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
