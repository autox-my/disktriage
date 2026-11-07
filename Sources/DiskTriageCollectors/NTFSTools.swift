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
    ///
    /// `executablePath` is the running binary's path. It is injected (rather
    /// than read from the process) so tests can build a Homebrew keg layout in
    /// a temporary directory; the live callers pass `Bundle.main.executablePath`.
    public static func locate(
        environment: [String: String],
        executablePath: String? = nil
    ) -> NTFSToolchain? {
        guard let info = resolve("ntfsinfo", environment: environment, executablePath: executablePath),
              let ls = resolve("ntfsls", environment: environment, executablePath: executablePath)
        else { return nil }
        return NTFSToolchain(ntfsinfo: info, ntfsls: ls)
    }

    /// `mkntfs` lives in `sbin/` in the spike's prefix, which is why the prefix
    /// and the installed tree each contribute both directories.
    ///
    /// Order: `DISKTRIAGE_NTFS_PREFIX`, the installed keg's
    /// `../libexec/ntfs-3g` beside the *resolved* executable, PATH, then the
    /// usual Homebrew/system directories. The installed tree sits before PATH
    /// because `sudo` strips the environment that carries the prefix and brew
    /// symlinks `bin/disktriage` into the keg.
    public static func resolve(
        _ name: String,
        environment: [String: String],
        executablePath: String? = nil
    ) -> String? {
        var directories: [String] = []
        if let prefix = environment[prefixVariable], !prefix.isEmpty {
            directories += [prefix + "/bin", prefix + "/sbin", prefix]
        }
        if let executablePath {
            directories += executableRelativeDirectories(executablePath: executablePath)
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

    /// `<directory of the resolved executable>/../libexec/ntfs-3g/{bin,sbin}`.
    /// The symlink resolution is load-bearing: brew installs
    /// `/opt/homebrew/bin/disktriage -> ../Cellar/disktriage/<version>/bin/disktriage`,
    /// and the un-resolved parent would be `/opt/homebrew/libexec`.
    public static func executableRelativeDirectories(executablePath: String) -> [String] {
        guard let installed = installedPrefix(executablePath: executablePath) else { return [] }
        return [installed + "/bin", installed + "/sbin"]
    }

    /// The keg's `libexec/ntfs-3g`, or `nil` when the executable path is
    /// empty. Used by `check` and the missing-tools messages to name the
    /// location a Homebrew install uses.
    public static func installedPrefix(executablePath: String?) -> String? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let executable: URL
        if executablePath.hasPrefix("/") {
            executable = URL(fileURLWithPath: executablePath)
        } else {
            executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(executablePath)
        }
        return executable.standardizedFileURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()   // bin/
            .deletingLastPathComponent()   // the keg (or prefix) root
            .appendingPathComponent("libexec/ntfs-3g", isDirectory: true)
            .path
    }

    /// The directories a lookup visits, in order, as one sentence. A failure
    /// that does not name them turns "the prefix was not exported" into
    /// "the tool is missing".
    public static func searchDescription(
        environment: [String: String],
        executablePath: String? = nil
    ) -> String {
        var parts: [String] = []
        if let prefix = environment[prefixVariable], !prefix.isEmpty {
            parts.append("\(prefixVariable)=\(prefix) (bin/, sbin/)")
        }
        if let installed = installedPrefix(executablePath: executablePath) {
            parts.append("\(installed) (bin/, sbin/)")
        }
        parts.append("PATH")
        parts.append("/opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin, /sbin")
        return parts.joined(separator: ", ")
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String? = Bundle.main.executablePath
    ) -> NTFSToolRunner? {
        guard let chain = NTFSToolLocator.locate(
            environment: environment,
            executablePath: executablePath
        ) else { return nil }
        let runner = ProcessRunner(
            policy: .inspect,
            timeout: recursiveListingTimeout,
            outputLimit: outputLimit
        )
        return NTFSToolRunner(toolchain: chain, executor: runner)
    }
}
