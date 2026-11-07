import Foundation

/// Where the ntfs-3g userspace tools were found. The same rules as the
/// self-test's row: `DISKTRIAGE_NTFS_PREFIX` (a built tree with `bin/`, and
/// `sbin/` for `mkntfs`), then PATH, then the usual Homebrew/system
/// directories. There is deliberately no mount fallback.
public struct NTFSToolchain: Equatable, Sendable {
    public let ntfsinfo: String
    public let ntfsls: String

    public init(ntfsinfo: String, ntfsls: String) {
        self.ntfsinfo = ntfsinfo
        self.ntfsls = ntfsls
    }
}

public enum NTFSToolLocator {
    public static let prefixVariable = "DISKTRIAGE_NTFS_PREFIX"

    /// `nil` means the tool is not installed. The caller turns that into exit
    /// 30 with an actionable message; it never falls back to a mount.
    public static func locate(environment: [String: String]) -> NTFSToolchain? {
        guard let info = resolve("ntfsinfo", environment: environment),
              let ls = resolve("ntfsls", environment: environment)
        else { return nil }
        return NTFSToolchain(ntfsinfo: info, ntfsls: ls)
    }

    /// `mkntfs` lives in `sbin/` in the spike's prefix, which is why the prefix
    /// contributes both directories.
    public static func resolve(_ name: String, environment: [String: String]) -> String? {
        var directories: [String] = []
        if let prefix = environment[prefixVariable], !prefix.isEmpty {
            directories += [prefix + "/bin", prefix + "/sbin", prefix]
        }
        if let path = environment["PATH"] {
            directories += path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/sbin"]

        var seen: Set<String> = []
        for directory in directories where seen.insert(directory).inserted {
            let candidate = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// The two read-only calls `inspect` makes. Injected, so the CLI tests drive
/// recorded output and never a subprocess.
public protocol NTFSToolRunning: Sendable {
    func volumeInfo(image: String) -> CollectorResult
    func listing(image: String, recursive: Bool) -> CollectorResult
}

/// The live runner. Every call goes through `ProcessRunner` with the inspect
/// allow-list, a hard timeout and a process-group kill. A recursive listing
/// gets a longer budget than the root listing because it is the one call whose
/// output scales with the volume.
public struct NTFSToolRunner: NTFSToolRunning, Sendable {
    public static let volumeTimeout: TimeInterval = 30
    public static let rootListingTimeout: TimeInterval = 30
    public static let recursiveListingTimeout: TimeInterval = 120
    /// 4 MiB: the spike measured 1.78 MB for 10,001 inodes; the cap is a work
    /// limit, and crossing it is reported as a partial listing, never ignored.
    public static let outputLimit = 4_194_304

    public let toolchain: NTFSToolchain
    private let executor: any CommandExecuting

    public init(toolchain: NTFSToolchain, executor: any CommandExecuting) {
        self.toolchain = toolchain
        self.executor = executor
    }

    public func volumeInfo(image: String) -> CollectorResult {
        let command = TriageCommand.ntfsTool(path: toolchain.ntfsinfo, arguments: ["-m", image])
        return executor.run(command, timeout: Self.volumeTimeout)
    }

    public func listing(image: String, recursive: Bool) -> CollectorResult {
        let command = TriageCommand.ntfsTool(
            path: toolchain.ntfsls,
            arguments: [recursive ? "-R" : "-l", image]
        )
        return executor.run(
            command,
            timeout: recursive ? Self.recursiveListingTimeout : Self.rootListingTimeout
        )
    }

    /// The shipped runner's policy is `.inspect`, so no caller can reach the
    /// triage shapes (or a writer) through it.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NTFSToolRunner? {
        guard let chain = NTFSToolLocator.locate(environment: environment) else { return nil }
        let runner = ProcessRunner(
            policy: .inspect,
            timeout: recursiveListingTimeout,
            outputLimit: outputLimit
        )
        return NTFSToolRunner(toolchain: chain, executor: runner)
    }
}
