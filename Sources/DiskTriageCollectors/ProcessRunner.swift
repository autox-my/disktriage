import Foundation
import Darwin

/// A collector that can be driven with a recorded result in tests.
public protocol CommandExecuting: Sendable {
    func run(_ command: TriageCommand) -> CollectorResult
    /// A command whose cost scales with its input (the unified-log window) can
    /// ask for its own hard timeout. The default ignores it and keeps the
    /// executor's configured timeout.
    func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult
    /// The same call with stdout kept as bytes (`copy` reads file data through
    /// `ntfscat`). The default encodes a recorded string result, which is all a
    /// text-only test executor needs.
    func runData(_ command: TriageCommand, timeout: TimeInterval) -> CommandDataResult
}

public extension CommandExecuting {
    func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult {
        run(command)
    }

    func runData(_ command: TriageCommand, timeout: TimeInterval) -> CommandDataResult {
        let result = run(command, timeout: timeout)
        return CommandDataResult(
            outcome: result.outcome,
            exitCode: result.exitCode,
            stdout: Data(result.stdout.utf8),
            stderr: result.stderr,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated,
            durationMs: result.durationMs,
            policyViolation: result.policyViolation
        )
    }
}

/// Runs one allow-listed argv in its own process group with a hard timeout.
///
/// The timeout is enforced by killing the whole group (`TERM`, then `KILL`), so
/// a wedged child or grandchild cannot outlive the triage run (diskdoctor.md
/// §2.7, REQ-0011). stdout and stderr are drained concurrently while the child
/// runs, so a command that writes megabytes cannot deadlock on a full pipe.
public struct ProcessRunner: CommandExecuting, Sendable {
    /// The explicit environment every collector runs with: no inherited
    /// secrets, a fixed `PATH`, and a stable locale.
    public static let environment = [
        "LC_ALL=C",
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
    ]

    public static let defaultOutputLimit = 1_048_576

    public let timeout: TimeInterval
    public let outputLimit: Int
    let policy: CommandPolicy

    public init(timeout: TimeInterval = 10, outputLimit: Int = ProcessRunner.defaultOutputLimit) {
        self.init(policy: .triage, timeout: timeout, outputLimit: outputLimit)
    }

    /// Test-only: injection is internal so the shipped runner always carries
    /// `CommandPolicy.triage`.
    init(policy: CommandPolicy, timeout: TimeInterval, outputLimit: Int) {
        self.policy = policy
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func run(_ command: TriageCommand) -> CollectorResult {
        execute(command.argv, timeout: timeout)
    }

    /// A per-command hard timeout, for a query whose cost scales with its input
    /// (the unified-log window). The process-group kill is unchanged.
    public func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult {
        execute(command.argv, timeout: timeout)
    }

    public func run(argv: [String]) -> CollectorResult {
        execute(argv, timeout: timeout)
    }

    public func runData(_ command: TriageCommand, timeout: TimeInterval) -> CommandDataResult {
        let raw = executeRaw(command.argv, timeout: timeout)
        return CommandDataResult(
            outcome: raw.outcome,
            exitCode: raw.exitCode,
            stdout: raw.stdout,
            stderr: raw.stderr,
            stdoutTruncated: raw.stdoutTruncated,
            stderrTruncated: raw.stderrTruncated,
            durationMs: raw.durationMs,
            policyViolation: raw.policyViolation
        )
    }

    private func execute(_ argv: [String], timeout: TimeInterval) -> CollectorResult {
        let raw = executeRaw(argv, timeout: timeout)
        return CollectorResult(
            outcome: raw.outcome,
            exitCode: raw.exitCode,
            stdout: String(decoding: raw.stdout, as: UTF8.self),
            stderr: raw.stderr,
            stdoutTruncated: raw.stdoutTruncated,
            stderrTruncated: raw.stderrTruncated,
            durationMs: raw.durationMs,
            policyViolation: raw.policyViolation
        )
    }

    private struct RawResult {
        var outcome: CollectOutcome
        var exitCode: Int32?
        var stdout: Data
        var stderr: String
        var stdoutTruncated: Bool
        var stderrTruncated: Bool
        var durationMs: Int
        var policyViolation: PolicyViolation?

        init(
            outcome: CollectOutcome,
            exitCode: Int32? = nil,
            stdout: Data = Data(),
            stderr: String = "",
            stdoutTruncated: Bool = false,
            stderrTruncated: Bool = false,
            durationMs: Int = 0,
            policyViolation: PolicyViolation? = nil
        ) {
            self.outcome = outcome
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.stdoutTruncated = stdoutTruncated
            self.stderrTruncated = stderrTruncated
            self.durationMs = durationMs
            self.policyViolation = policyViolation
        }
    }

    private func executeRaw(_ argv: [String], timeout: TimeInterval) -> RawResult {
        let started = DispatchTime.now().uptimeNanoseconds

        switch policy.evaluate(argv) {
        case .rejected(let violation):
            return RawResult(
                outcome: .policyRejected,
                stderr: "rejected before exec: \(violation.rawValue)",
                durationMs: elapsedMs(since: started),
                policyViolation: violation
            )
        case .allowed:
            break
        }

        guard let path = resolveExecutable(argv[0]) else {
            return RawResult(
                outcome: .notFound,
                stderr: "not found: \(argv[0])",
                durationMs: elapsedMs(since: started)
            )
        }

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            return RawResult(
                outcome: .error,
                stderr: "cannot create pipes: \(String(cString: strerror(errno)))",
                durationMs: elapsedMs(since: started)
            )
        }

        var childPID: pid_t = 0
        let spawnResult = spawn(
            path: path,
            argv: argv,
            environment: ProcessRunner.environment,
            stdout: stdoutPipe[1],
            stderr: stderrPipe[1],
            pid: &childPID
        )
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnResult == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return RawResult(
                outcome: spawnFailureOutcome(spawnResult),
                stderr: "cannot spawn: \(String(cString: strerror(spawnResult)))",
                durationMs: elapsedMs(since: started)
            )
        }

        // Drain both pipes while the child runs. The readers only touch their
        // own file descriptors and a locked box.
        let stdoutBox = Locked(Drained(data: Data(), truncated: false))
        let stderrBox = Locked(Drained(data: Data(), truncated: false))
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBox.value = drain(fd: stdoutPipe[0], limit: outputLimit)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.value = drain(fd: stderrPipe[0], limit: outputLimit)
            readers.leave()
        }

        var status: Int32 = 0
        let timedOut = waitForExit(pid: childPID, status: &status, limit: timeout)
        if timedOut {
            kill(-childPID, SIGTERM)
            var reaped = waitForReap(pid: childPID, status: &status, limit: 0.5)
            // Sweep the whole group even when the leader already exited: a
            // surviving grandchild is exactly the row-10 failure.
            kill(-childPID, SIGKILL)
            if !reaped {
                reaped = waitForReap(pid: childPID, status: &status, limit: 0.5)
            }
        }

        _ = readers.wait(timeout: .now() + timeout + 2)
        close(stdoutPipe[0])
        close(stderrPipe[0])

        let out = stdoutBox.value
        let err = stderrBox.value
        let duration = elapsedMs(since: started)

        if timedOut {
            return RawResult(
                outcome: .timeout,
                exitCode: exitCode(from: status),
                stdout: out.data,
                stderr: String(decoding: err.data, as: UTF8.self),
                stdoutTruncated: out.truncated,
                stderrTruncated: err.truncated,
                durationMs: duration
            )
        }

        let code = exitCode(from: status)
        return RawResult(
            outcome: code == 0 && wasExited(status) ? .ok : .error,
            exitCode: code,
            stdout: out.data,
            stderr: String(decoding: err.data, as: UTF8.self),
            stdoutTruncated: out.truncated,
            stderrTruncated: err.truncated,
            durationMs: duration
        )
    }
}

// MARK: - Waiting

/// Polls `waitpid(WNOHANG)` up to `limit` seconds. Returns true when the
/// deadline passed first.
private func waitForExit(pid: pid_t, status: inout Int32, limit: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while Date() < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return false
        }
        if result == -1 && errno != EINTR {
            return false
        }
        usleep(5_000)
    }
    return true
}

/// Polls after a signal. Returns true when the child was reaped.
private func waitForReap(pid: pid_t, status: inout Int32, limit: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while Date() < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return true
        }
        if result == -1 && errno != EINTR {
            return true
        }
        usleep(5_000)
    }
    return false
}

private func elapsedMs(since started: UInt64) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
}

private func wasExited(_ status: Int32) -> Bool {
    (status & 0x7F) == 0
}

private func exitCode(from status: Int32) -> Int32? {
    if wasExited(status) {
        return (status >> 8) & 0xFF
    }
    let signal = status & 0x7F
    return signal == 0 ? nil : 128 + signal
}

// MARK: - Spawning

/// `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, so the child leads a new group
/// and `kill(-pid, …)` reaches every descendant.
private func spawn(
    path: String,
    argv: [String],
    environment: [String],
    stdout: Int32,
    stderr: Int32,
    pid: inout pid_t
) -> Int32 {
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return errno }
    defer { posix_spawn_file_actions_destroy(&actions) }

    posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, stdout)
    posix_spawn_file_actions_addclose(&actions, stderr)

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return errno }
    defer { posix_spawnattr_destroy(&attributes) }

    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    var argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    argvPointers.append(nil)
    var envPointers: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }
    envPointers.append(nil)
    defer {
        argvPointers.dropLast().forEach { free($0) }
        envPointers.dropLast().forEach { free($0) }
    }

    return argvPointers.withUnsafeBufferPointer { argvBuffer in
        envPointers.withUnsafeBufferPointer { envBuffer in
            posix_spawn(
                &pid,
                path,
                &actions,
                &attributes,
                argvBuffer.baseAddress,
                envBuffer.baseAddress
            )
        }
    }
}

private func spawnFailureOutcome(_ code: Int32) -> CollectOutcome {
    switch code {
    case ENOENT, ENOTDIR:
        return .notFound
    case EACCES, EPERM:
        return .denied
    default:
        return .error
    }
}

/// Resolves argv[0] against the sanitised PATH; an absolute path is used as is.
/// No shell is ever involved.
private func resolveExecutable(_ name: String) -> String? {
    if name.hasPrefix("/") {
        // A path that exists but is not executable must reach `posix_spawn`
        // so EACCES becomes `denied`, not `notFound`.
        return FileManager.default.fileExists(atPath: name) ? name : nil
    }
    for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"] {
        let candidate = directory + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

// MARK: - Draining

private struct Drained: Sendable {
    var data: Data
    var truncated: Bool
}

/// Reads until EOF, keeping at most `limit` bytes but continuing to consume so
/// the child never blocks on a full pipe.
private func drain(fd: Int32, limit: Int) -> Drained {
    var data = Data()
    var truncated = false
    var buffer = [UInt8](repeating: 0, count: 65_536)

    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            if data.count < limit {
                let keep = min(count, limit - data.count)
                data.append(contentsOf: buffer[0..<keep])
                if keep < count {
                    truncated = true
                }
            } else {
                truncated = true
            }
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            break
        }
    }
    return Drained(data: data, truncated: truncated)
}

/// `DispatchQueue` closures need Sendable storage; the lock makes the two
/// reader results safe to hand back to the caller.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
