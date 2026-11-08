import Foundation
import DiskTriageCore

/// The native read-only attach for APFS, HFS+, exFAT and FAT images
/// (docs/adr/0025). It is deliberately a small, injectable seam: the CLI drives
/// it, and the tests drive recorded command output, never a subprocess.
///
/// The route is measured on macOS 27.2:
///
/// 1. `diskutil image attach --noMount --readOnly <image>` — no automount;
/// 2. `diskutil info -plist <dev>` — name, filesystem and lock state;
/// 3. `diskutil mount readOnly nobrowse -mountPoint <dir> <dev>` — an explicit
///    read-only mount that needs no root (the `/sbin/mount` form needs root on
///    this host and fails with exit 71);
/// 4. `diskutil unmount <dev>`, then `diskutil eject <whole-disk>`.
///
/// Every step has a hard timeout and the process-group kill from
/// `ProcessRunner`. The only writable mount in the repository is the fixture
/// generator's, and it is not product code.
public struct NativeAttachedVolume: Equatable, Sendable {
    public let device: String
    public let name: String?
    public let filesystem: NativeFilesystem
    public let encrypted: Bool
    public let locked: Bool

    public init(
        device: String,
        name: String?,
        filesystem: NativeFilesystem,
        encrypted: Bool = false,
        locked: Bool = false
    ) {
        self.device = device
        self.name = name
        self.filesystem = filesystem
        self.encrypted = encrypted
        self.locked = locked
    }
}

/// The exact disk this run attached, and the volumes the attach produced.
/// `wholeDisk` is what cleanup ejects; nothing else is ever detached.
public struct NativeAttachment: Equatable, Sendable {
    public let wholeDisk: String
    public let volumes: [NativeAttachedVolume]

    public init(wholeDisk: String, volumes: [NativeAttachedVolume]) {
        self.wholeDisk = wholeDisk
        self.volumes = volumes
    }
}

public enum NativeAttachResult: Equatable, Sendable {
    case attached(NativeAttachment)
    /// The tool is missing, denied or policy-rejected: no fallback exists.
    case unavailable(String)
    case failed(String)
    /// `partialWholeDisk` is the disk recovered from `hdiutil info` so a
    /// timed-out attach can still be detached. `nil` means none was found.
    case timedOut(String, partialWholeDisk: String?)
}

public enum NativeCommandResult: Equatable, Sendable {
    case ok
    case failed(String)
    case timedOut(String)
    case unavailable(String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .ok: return nil
        case .failed(let message), .timedOut(let message), .unavailable(let message):
            return message
        }
    }
}

public protocol NativeAttachRunning: Sendable {
    func attachReadOnly(image: String) -> NativeAttachResult
    func mountReadOnly(volume: String, mountPoint: String) -> NativeCommandResult
    func unmount(volume: String) -> NativeCommandResult
    func detach(wholeDisk: String) -> NativeCommandResult
}

/// The live runner. The injected `CommandExecuting` carries
/// `CommandPolicy.native`; the tests inject a recorded executor and the shipped
/// caller uses `ProcessRunner(policy: .native, ...)`.
public struct LiveNativeAttachRunner: NativeAttachRunning {
    public static let attachTimeout: TimeInterval = 30
    public static let infoTimeout: TimeInterval = 15
    /// `diskutil mount` may wait up to a minute for DiskArbitration, so its
    /// hard timeout is longer than the other calls.
    public static let mountTimeout: TimeInterval = 65
    public static let unmountTimeout: TimeInterval = 30
    public static let detachTimeout: TimeInterval = 30
    public static let outputLimit = 1_048_576

    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting) {
        self.executor = executor
    }

    public static func live() -> LiveNativeAttachRunner {
        LiveNativeAttachRunner(
            executor: ProcessRunner(
                policy: .native,
                timeout: attachTimeout,
                outputLimit: outputLimit
            )
        )
    }

    public func attachReadOnly(image: String) -> NativeAttachResult {
        let result = executor.run(TriageCommand.nativeAttach(image: image), timeout: Self.attachTimeout)
        switch result.outcome {
        case .ok:
            return parseAttach(result.stdout, image: image)
        case .timeout:
            return .timedOut(
                "diskutil image attach did not answer within \(Int(Self.attachTimeout)) s",
                partialWholeDisk: recoverWholeDisk(image: image)
            )
        case .notFound:
            return .unavailable(
                "diskutil was not found; the native read-only attach is unavailable "
                    + "(no writable or third-party fallback is attempted)"
            )
        case .denied:
            return .unavailable(
                "diskutil image attach was denied: "
                    + (firstLine(result.stderr) ?? "no message")
            )
        case .policyRejected:
            return .unavailable(
                "the diskutil image attach command was rejected by the command policy"
            )
        case .error:
            return .failed(
                "diskutil image attach failed: "
                    + (firstLine(result.stderr)
                        ?? "exit \(result.exitCode.map(String.init) ?? "on a signal")")
            )
        }
    }

    public func mountReadOnly(volume: String, mountPoint: String) -> NativeCommandResult {
        let result = executor.run(
            TriageCommand.nativeMount(volume: volume, mountPoint: mountPoint),
            timeout: Self.mountTimeout
        )
        return commandResult(result, what: "diskutil mount")
    }

    public func unmount(volume: String) -> NativeCommandResult {
        let result = executor.run(
            TriageCommand.nativeUnmount(volume: volume),
            timeout: Self.unmountTimeout
        )
        return commandResult(result, what: "diskutil unmount")
    }

    public func detach(wholeDisk: String) -> NativeCommandResult {
        let result = executor.run(
            TriageCommand.nativeDetach(wholeDisk: wholeDisk),
            timeout: Self.detachTimeout
        )
        return commandResult(result, what: "diskutil eject")
    }

    // MARK: - Attach output

    /// The first line is the whole disk; every `/dev/disk*` line is then asked
    /// for its own info. A bare-volume image attaches as one whole disk that
    /// *is* the volume, so the first line can also be a volume.
    func parseAttach(_ stdout: String, image: String) -> NativeAttachResult {
        var devices: [String] = []
        var seen: Set<String> = []
        for rawLine in stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces)
                ?? line.split(separator: " ").first.map(String.init)
            else { continue }
            guard first.hasPrefix("/dev/disk") else { continue }
            if seen.insert(first).inserted { devices.append(first) }
        }
        guard let wholeDisk = devices.first else {
            return .failed("diskutil image attach exited 0 but named no /dev/disk node")
        }

        var volumes: [NativeAttachedVolume] = []
        for device in devices {
            let info = executor.run(TriageCommand.nativeInfo(device: device), timeout: Self.infoTimeout)
            switch info.outcome {
            case .ok:
                if let volume = Self.parseInfo(info.stdout, device: device) {
                    volumes.append(volume)
                }
            case .timeout:
                return .failed("diskutil info \(device) did not answer within \(Int(Self.infoTimeout)) s")
            case .notFound:
                return .unavailable("diskutil was not found while reading \(device)")
            case .denied:
                return .unavailable(
                    "diskutil info \(device) was denied: "
                        + (firstLine(info.stderr) ?? "no message")
                )
            case .policyRejected:
                return .unavailable("the diskutil info command was rejected by the command policy")
            case .error:
                return .failed(
                    "diskutil info \(device) failed: "
                        + (firstLine(info.stderr)
                            ?? "exit \(info.exitCode.map(String.init) ?? "on a signal")")
                )
            }
        }

        return .attached(NativeAttachment(wholeDisk: wholeDisk, volumes: volumes))
    }

    /// `FilesystemType`, `VolumeName`, `Locked` and `Encrypted` from the plist.
    /// A volume with no recognised filesystem (a partition scheme, an APFS
    /// physical store or a container) is not a mountable volume.
    static func parseInfo(_ text: String, device: String) -> NativeAttachedVolume? {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let object = plist as? [String: Any],
              let type = object["FilesystemType"] as? String,
              let filesystem = NativeFilesystem(diskutilType: type)
        else { return nil }

        let name = (object["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let locked = object["Locked"] as? Bool ?? false
        let encrypted = (object["Encrypted"] as? Bool ?? false) || locked
        return NativeAttachedVolume(
            device: device,
            name: name,
            filesystem: filesystem,
            encrypted: encrypted,
            locked: locked
        )
    }

    /// Best-effort recovery for a timed-out attach: `hdiutil info` names the
    /// image path and the `/dev/disk` node it produced. Only an exact path
    /// match is accepted; an image that is not ours is never returned.
    func recoverWholeDisk(image: String) -> String? {
        let result = executor.run(TriageCommand.hdiutilInfo, timeout: Self.infoTimeout)
        guard result.outcome == .ok else { return nil }
        let wanted = URL(fileURLWithPath: image).standardizedFileURL.path
        var currentPath: String?
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("image-path") {
                currentPath = line
                    .split(separator: ":", maxSplits: 1)
                    .dropFirst()
                    .first?
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("/dev/disk"), currentPath == wanted {
                let device = line.split(separator: "\t").first.map(String.init) ?? line
                return device.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("=====") {
                currentPath = nil
            }
        }
        return nil
    }

    private func commandResult(_ result: CollectorResult, what: String) -> NativeCommandResult {
        switch result.outcome {
        case .ok:
            return .ok
        case .timeout:
            return .timedOut("\(what) did not answer within its hard timeout")
        case .notFound:
            return .unavailable("\(what) was not found; the native read-only path is unavailable")
        case .denied:
            return .unavailable("\(what) was denied: " + (firstLine(result.stderr) ?? "no message"))
        case .policyRejected:
            return .unavailable("the \(what) command was rejected by the command policy")
        case .error:
            return .failed(
                "\(what) failed: "
                    + (firstLine(result.stderr)
                        ?? "exit \(result.exitCode.map(String.init) ?? "on a signal")")
            )
        }
    }
}

// MARK: - Cleanup

/// The result of unmounting then detaching the one disk a run attached.
public struct NativeCleanupOutcome: Equatable, Sendable {
    public let wholeDisk: String
    public let unmount: NativeCommandResult?
    public let detach: NativeCommandResult
}

/// One run's lease on one attached image. `cleanup` is idempotent, always
/// unmounts the exact volume it mounted (when a mount was attempted) and then
/// ejects the exact whole disk the attach named. It cannot name another disk:
/// `wholeDisk` is fixed at init from the attach output.
public final class NativeAttachmentLease: @unchecked Sendable {
    private let lock = NSLock()
    private let runner: any NativeAttachRunning
    private let wholeDisk: String
    private var mountAttemptedVolume: String?
    private var cleaned = false

    public init(runner: any NativeAttachRunning, wholeDisk: String) {
        self.runner = runner
        self.wholeDisk = wholeDisk
    }

    /// Recorded **before** the mount call, so a mount that times out (and may
    /// still have mounted) is still unmounted by cleanup.
    public func recordMountAttempt(_ volume: String) {
        lock.lock()
        mountAttemptedVolume = volume
        lock.unlock()
    }

    public func recordUnmount() {
        lock.lock()
        mountAttemptedVolume = nil
        lock.unlock()
    }

    public var disk: String { wholeDisk }

    @discardableResult
    public func cleanup() -> NativeCleanupOutcome {
        lock.lock()
        if cleaned {
            lock.unlock()
            return NativeCleanupOutcome(wholeDisk: wholeDisk, unmount: nil, detach: .ok)
        }
        cleaned = true
        let volume = mountAttemptedVolume
        mountAttemptedVolume = nil
        lock.unlock()

        let unmountResult = volume.map { runner.unmount(volume: $0) }
        let detachResult = runner.detach(wholeDisk: wholeDisk)
        NativeCleanupRegistry.shared.unregister(self)
        return NativeCleanupOutcome(
            wholeDisk: wholeDisk,
            unmount: unmountResult,
            detach: detachResult
        )
    }
}

/// The process-wide set of live leases. The SIGINT/SIGTERM handler and the
/// normal `defer` both call `cleanupAll`; a second call finds the leases
/// already cleaned and does nothing.
public final class NativeCleanupRegistry: @unchecked Sendable {
    public static let shared = NativeCleanupRegistry()

    private let lock = NSLock()
    private var leases: [NativeAttachmentLease] = []

    public init() {}

    public func register(_ lease: NativeAttachmentLease) {
        lock.lock()
        leases.append(lease)
        lock.unlock()
    }

    public func unregister(_ lease: NativeAttachmentLease) {
        lock.lock()
        leases.removeAll { $0 === lease }
        lock.unlock()
    }

    @discardableResult
    public func cleanupAll() -> [NativeCleanupOutcome] {
        lock.lock()
        let current = leases
        leases.removeAll()
        lock.unlock()
        return current.map { $0.cleanup() }
    }

    public var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return leases.count
    }
}

/// SIGINT/SIGTERM cleanup. A signal source runs the cleanup on a dispatch
/// queue (not in the signal context), so spawning `diskutil unmount`/`eject` is
/// safe. `handleForTesting` is the same path without `exit`, for the suite.
public enum NativeSignalTrap {
    private static let state = SignalTrapState()

    public static func install() {
        state.install()
    }

    /// Runs the same cleanup the installed handler runs and returns the shell
    /// status (`128 + signal`). The live handler calls this and exits. The
    /// registry is injectable so a parallel test can use its own lease set
    /// without touching another test's live attach.
    public static func handleForTesting(
        _ signal: Int32,
        registry: NativeCleanupRegistry = .shared
    ) -> Int32 {
        registry.cleanupAll()
        return 128 + signal
    }

    public static var isInstalled: Bool { state.isInstalled }
}

private final class SignalTrapState: @unchecked Sendable {
    private let lock = NSLock()
    private var installed = false
    private var sources: [DispatchSourceSignal] = []

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    func install() {
        lock.lock()
        guard !installed else {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                let code = NativeSignalTrap.handleForTesting(sig)
                exit(code)
            }
            source.resume()
            lock.lock()
            sources.append(source)
            lock.unlock()
        }
    }
}

// MARK: - Small helpers

func firstLine(_ text: String) -> String? {
    let line = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n")
        .first
        .map(String.init)
    return line?.isEmpty == false ? line : nil
}
