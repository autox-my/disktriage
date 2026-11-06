import Foundation
import Darwin
import DiskTriageCollectors

/// One ddrescue process, as the supervisor sees it. `poll` is non-blocking so
/// the mapfile can be read and the device checked while ddrescue runs.
public protocol DdrescueProcessHandle: AnyObject {
    var pid: Int32 { get }
    /// `nil` while running, otherwise the exit status (`128 + signal` for a
    /// signal death).
    func poll() -> Int32?
    /// Signals the process group, so the `caffeinate` wrapper and ddrescue are
    /// reached together.
    func signal(_ signal: Int32)
}

/// The injectable launcher. Tests supply a fake that rewrites a mapfile; the
/// shipped one is `PosixDdrescueLauncher`.
public protocol DdrescueLaunching {
    func launch(argv: [String]) throws -> any DdrescueProcessHandle
}

public struct DdrescueLaunchError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// `posix_spawn` in a new process group, with the parent's stdout/stderr. No
/// shell is involved; the argv is exactly the one the dry-run printed.
public struct PosixDdrescueLauncher: DdrescueLaunching {
    public init() {}

    public func launch(argv: [String]) throws -> any DdrescueProcessHandle {
        guard let executable = Self.resolve(argv[0]) else {
            throw DdrescueLaunchError(message: "not found: \(argv[0])")
        }

        var pid: pid_t = 0
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw DdrescueLaunchError(message: String(cString: strerror(errno)))
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // ddrescue writes its progress to stderr, which stays the user's; its
        // stdout is unused. No child output can fill a stdout pipe.
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw DdrescueLaunchError(message: String(cString: strerror(errno)))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // A background test runner (and some shells) launch children with
        // SIGINT ignored, and an ignored disposition survives exec. ddrescue
        // must be able to install its own graceful SIGINT handler, so reset
        // the stop signals to their default action in the child.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // A blocked signal mask also survives exec; start the child with none.
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        var argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        argvPointers.append(nil)
        defer { argvPointers.dropLast().forEach { free($0) } }

        let result = argvPointers.withUnsafeBufferPointer { buffer in
            posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress, environ)
        }
        guard result == 0 else {
            throw DdrescueLaunchError(message: String(cString: strerror(result)))
        }
        return PosixDdrescueProcess(pid: pid)
    }

    private static func resolve(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin",
                          "/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

public final class PosixDdrescueProcess: DdrescueProcessHandle, @unchecked Sendable {
    public let pid: Int32
    private var exitCode: Int32?

    init(pid: Int32) {
        self.pid = pid
    }

    public func poll() -> Int32? {
        if let exitCode { return exitCode }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            exitCode = Self.code(from: status)
            return exitCode
        }
        if result == -1 && errno != EINTR {
            exitCode = 127
            return exitCode
        }
        return nil
    }

    public func signal(_ signal: Int32) {
        // Negative pid: the process group, so caffeinate and ddrescue both get
        // it and ddrescue can save its mapfile.
        kill(-pid, signal)
    }

    private static func code(from status: Int32) -> Int32 {
        if (status & 0x7F) == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }
}

/// Why a pass stopped.
public enum PassStopReason: String, Equatable, Sendable {
    case complete = "complete"
    case stopRule = "stop rule"
    case deviceDisappeared = "device disappeared"
    case ddrescueError = "ddrescue error"
    case interrupted = "interrupted"
    case launchFailed = "launch failed"
}

public struct PassResult: Equatable, Sendable {
    public let pass: Int
    public let reason: PassStopReason
    public let exitCode: Int32?
    public let stop: Pass2Stop?
    public let snapshot: MapfileSnapshot?
    public let launchError: String?

    public init(
        pass: Int,
        reason: PassStopReason,
        exitCode: Int32? = nil,
        stop: Pass2Stop? = nil,
        snapshot: MapfileSnapshot? = nil,
        launchError: String? = nil
    ) {
        self.pass = pass
        self.reason = reason
        self.exitCode = exitCode
        self.stop = stop
        self.snapshot = snapshot
        self.launchError = launchError
    }
}

/// A concise stderr progress line's data.
public struct ImagingProgress: Equatable, Sendable {
    public let pass: Int
    public let rescuedBytes: Int64
    public let badBytes: Int64
    public let remainingBytes: Int64
    public let percent: Double

    public init(pass: Int, rescuedBytes: Int64, badBytes: Int64, remainingBytes: Int64, percent: Double) {
        self.pass = pass
        self.rescuedBytes = rescuedBytes
        self.badBytes = badBytes
        self.remainingBytes = remainingBytes
        self.percent = percent
    }
}

/// Runs one ddrescue pass under supervision: it reads the mapfile while the
/// process runs, applies the pass-2 stop rule, watches the device, and sends
/// SIGINT (then SIGTERM) when it must stop. It never polls SMART: the plan
/// forbids it while imaging (REQ-0082).
public struct DdrescueSupervisor {
    public struct Configuration {
        public let mapfilePath: String
        public let devicePath: String
        public let deviceSize: Int64
        public let pollInterval: TimeInterval
        public let signalGrace: TimeInterval
        public let readMapfile: (String) -> String?
        public let deviceExists: (String) -> Bool
        public let now: () -> Date
        public let sleep: (TimeInterval) -> Void
        public let interruptRequested: () -> Bool
        public let progress: (ImagingProgress) -> Void

        public init(
            mapfilePath: String,
            devicePath: String,
            deviceSize: Int64,
            pollInterval: TimeInterval,
            signalGrace: TimeInterval,
            readMapfile: @escaping (String) -> String?,
            deviceExists: @escaping (String) -> Bool,
            now: @escaping () -> Date,
            sleep: @escaping (TimeInterval) -> Void,
            interruptRequested: @escaping () -> Bool,
            progress: @escaping (ImagingProgress) -> Void
        ) {
            self.mapfilePath = mapfilePath
            self.devicePath = devicePath
            self.deviceSize = deviceSize
            self.pollInterval = pollInterval
            self.signalGrace = signalGrace
            self.readMapfile = readMapfile
            self.deviceExists = deviceExists
            self.now = now
            self.sleep = sleep
            self.interruptRequested = interruptRequested
            self.progress = progress
        }
    }

    private let launcher: any DdrescueLaunching
    private let configuration: Configuration

    public init(launcher: any DdrescueLaunching, configuration: Configuration) {
        self.launcher = launcher
        self.configuration = configuration
    }

    public func run(_ pass: DdrescuePass, applyStopRule: Bool) -> PassResult {
        let handle: any DdrescueProcessHandle
        do {
            handle = try launcher.launch(argv: pass.argv)
        } catch let error as DdrescueLaunchError {
            return PassResult(
                pass: pass.pass,
                reason: .launchFailed,
                snapshot: snapshot(),
                launchError: error.message
            )
        } catch {
            return PassResult(
                pass: pass.pass,
                reason: .launchFailed,
                snapshot: snapshot(),
                launchError: error.localizedDescription
            )
        }

        var history: [Pass2Sample] = []
        var lastSnapshot: MapfileSnapshot?

        while true {
            if let current = snapshot() {
                lastSnapshot = current
                if applyStopRule {
                    history.append(Pass2Sample(time: configuration.now(), rescuedBytes: current.rescuedBytes))
                    if case let .stop(stop) = pass2StopDecision(
                        history: history,
                        deviceSize: configuration.deviceSize,
                        now: configuration.now()
                    ) {
                        stopGracefully(handle)
                        return PassResult(
                            pass: pass.pass,
                            reason: .stopRule,
                            exitCode: handle.poll(),
                            stop: stop,
                            snapshot: snapshot() ?? lastSnapshot
                        )
                    }
                }
                configuration.progress(ImagingProgress(
                    pass: pass.pass,
                    rescuedBytes: current.rescuedBytes,
                    badBytes: current.badBytes,
                    remainingBytes: current.remainingBytes,
                    percent: current.rescuedFraction * 100
                ))
            }

            if configuration.interruptRequested() {
                stopGracefully(handle)
                return PassResult(
                    pass: pass.pass,
                    reason: .interrupted,
                    exitCode: handle.poll(),
                    snapshot: snapshot() ?? lastSnapshot
                )
            }

            if !configuration.deviceExists(configuration.devicePath) {
                stopGracefully(handle)
                return PassResult(
                    pass: pass.pass,
                    reason: .deviceDisappeared,
                    exitCode: handle.poll(),
                    snapshot: snapshot() ?? lastSnapshot
                )
            }

            if let exit = handle.poll() {
                let final = snapshot() ?? lastSnapshot
                return PassResult(
                    pass: pass.pass,
                    reason: exit == 0 ? .complete : .ddrescueError,
                    exitCode: exit,
                    snapshot: final
                )
            }

            configuration.sleep(configuration.pollInterval)
        }
    }

    private func snapshot() -> MapfileSnapshot? {
        guard let text = configuration.readMapfile(configuration.mapfilePath) else { return nil }
        return DdrescueMapfile.parse(text)
    }

    /// SIGINT first so ddrescue saves its mapfile; SIGTERM after the grace
    /// period; SIGKILL only if the tool would otherwise hang with the disk.
    private func stopGracefully(_ handle: any DdrescueProcessHandle) {
        handle.signal(SIGINT)
        if waitForExit(handle) != nil { return }
        handle.signal(SIGTERM)
        if waitForExit(handle) != nil { return }
        handle.signal(SIGKILL)
        _ = waitForExit(handle)
    }

    private func waitForExit(_ handle: any DdrescueProcessHandle) -> Int32? {
        let deadline = Date().addingTimeInterval(configuration.signalGrace)
        while Date() < deadline {
            if let exit = handle.poll() { return exit }
            configuration.sleep(0.05)
        }
        return handle.poll()
    }
}

// MARK: - Interrupts

/// A Ctrl-C on the terminal is a request to stop gracefully, not a reason to
/// orphan ddrescue. The handler only flips a flag; the supervisor sends SIGINT
/// to the process group and lets ddrescue save the mapfile.
public final class InterruptMonitor: @unchecked Sendable {
    public static let shared = InterruptMonitor()

    private let lock = NSLock()
    private var requested = false
    private var source: DispatchSourceSignal?

    public var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    public func install() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.requested = true
            self.lock.unlock()
        }
        source.resume()
        self.source = source
    }
}

// MARK: - Injected dependencies

/// Everything the executing image command needs from the outside world. The
/// live default is only built for a real run; tests pass a fake environment and
/// a fake launcher.
public struct ImagingDependencies {
    public var environment: any ImagingEnvironmentProbing
    public var launcher: any DdrescueLaunching
    public var pollInterval: TimeInterval
    public var signalGrace: TimeInterval
    public var sleep: (TimeInterval) -> Void
    public var readMapfile: (String) -> String?
    public var interruptRequested: () -> Bool

    public init(
        environment: any ImagingEnvironmentProbing,
        launcher: any DdrescueLaunching,
        pollInterval: TimeInterval = 2,
        signalGrace: TimeInterval = 5,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        readMapfile: @escaping (String) -> String? = {
            try? String(contentsOfFile: $0, encoding: .utf8)
        },
        interruptRequested: @escaping () -> Bool = { InterruptMonitor.shared.isRequested }
    ) {
        self.environment = environment
        self.launcher = launcher
        self.pollInterval = pollInterval
        self.signalGrace = signalGrace
        self.sleep = sleep
        self.readMapfile = readMapfile
        self.interruptRequested = interruptRequested
    }

    public static func live(executor: any CommandExecuting) -> ImagingDependencies {
        InterruptMonitor.shared.install()
        return ImagingDependencies(
            environment: LiveImagingEnvironment(executor: executor),
            launcher: PosixDdrescueLauncher()
        )
    }
}
