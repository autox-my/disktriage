import Foundation
import DiskTriageCore

/// The three extra tools `copy` needs beyond `inspect`'s volume/list pair.
public struct NTFSCopyToolchain: Equatable, Sendable {
    public let ntfsinfo: String
    public let ntfsls: String
    public let ntfscat: String
    public let ntfscluster: String

    public init(ntfsinfo: String, ntfsls: String, ntfscat: String, ntfscluster: String) {
        self.ntfsinfo = ntfsinfo
        self.ntfsls = ntfsls
        self.ntfscat = ntfscat
        self.ntfscluster = ntfscluster
    }
}

public enum NTFSCopyToolLocator {
    /// All four tools or nothing: a half-installed prefix must not make a copy
    /// look possible and then fail halfway through.
    public static func locate(environment: [String: String]) -> NTFSCopyToolchain? {
        guard let info = NTFSToolLocator.resolve("ntfsinfo", environment: environment),
              let ls = NTFSToolLocator.resolve("ntfsls", environment: environment),
              let cat = NTFSToolLocator.resolve("ntfscat", environment: environment),
              let cluster = NTFSToolLocator.resolve("ntfscluster", environment: environment)
        else { return nil }
        return NTFSCopyToolchain(ntfsinfo: info, ntfsls: ls, ntfscat: cat, ntfscluster: cluster)
    }
}

/// The read-only calls `copy` makes. Injected, so the CLI tests drive recorded
/// output (including binary `ntfscat` bytes) and never a subprocess.
public protocol NTFSCopyToolRunning: Sendable {
    func volumeInfo(image: String) -> CollectorResult
    /// `ntfsls -l -R`: names, sizes and directory headers in one call.
    func listing(image: String) -> CollectorResult
    /// `ntfscat <image> <volume-path>`: binary file data.
    func catFile(image: String, path: String) -> CommandDataResult
    /// `ntfscluster -c 0-(lastCluster) -v`: every inode's LCN runs in one pass.
    func clusterRuns(image: String, lastCluster: Int64) -> CollectorResult
}

/// The live runner. Every call goes through `ProcessRunner` with the inspect
/// allow-list, a hard timeout and a process-group kill.
public struct NTFSCopyToolRunner: NTFSCopyToolRunning, Sendable {
    public static let volumeTimeout: TimeInterval = 30
    public static let listingTimeout: TimeInterval = 120
    public static let catTimeout: TimeInterval = 120
    public static let clusterTimeout: TimeInterval = 120
    /// The spike measured 1.78 MB for 10,001 inodes. The process cap is a hard
    /// memory bound; hitting it means the map is incomplete and no per-file
    /// claim may be made.
    public static let clusterOutputLimit = 50_331_648 // 48 MiB

    public let toolchain: NTFSCopyToolchain

    private let volumeExecutor: any CommandExecuting
    private let listingExecutor: any CommandExecuting
    private let catExecutor: any CommandExecuting
    private let clusterExecutor: any CommandExecuting

    public init(toolchain: NTFSCopyToolchain, executor: any CommandExecuting) {
        self.init(
            toolchain: toolchain,
            volumeExecutor: executor,
            listingExecutor: executor,
            catExecutor: executor,
            clusterExecutor: executor
        )
    }

    public init(
        toolchain: NTFSCopyToolchain,
        volumeExecutor: any CommandExecuting,
        listingExecutor: any CommandExecuting,
        catExecutor: any CommandExecuting,
        clusterExecutor: any CommandExecuting
    ) {
        self.toolchain = toolchain
        self.volumeExecutor = volumeExecutor
        self.listingExecutor = listingExecutor
        self.catExecutor = catExecutor
        self.clusterExecutor = clusterExecutor
    }

    public func volumeInfo(image: String) -> CollectorResult {
        volumeExecutor.run(
            TriageCommand.ntfsTool(path: toolchain.ntfsinfo, arguments: ["-m", image]),
            timeout: Self.volumeTimeout
        )
    }

    public func listing(image: String) -> CollectorResult {
        listingExecutor.run(
            TriageCommand.ntfsTool(path: toolchain.ntfsls, arguments: ["-l", "-R", image]),
            timeout: Self.listingTimeout
        )
    }

    public func catFile(image: String, path: String) -> CommandDataResult {
        catExecutor.runData(
            TriageCommand.ntfsTool(path: toolchain.ntfscat, arguments: [image, path]),
            timeout: Self.catTimeout
        )
    }

    public func clusterRuns(image: String, lastCluster: Int64) -> CollectorResult {
        let range = "0-\(max(0, lastCluster))"
        return clusterExecutor.run(
            TriageCommand.ntfsTool(
                path: toolchain.ntfscluster,
                arguments: ["-c", range, "-v", image]
            ),
            timeout: Self.clusterTimeout
        )
    }

    /// The shipped runner's policy is `.inspect`, so no caller can reach a
    /// writer or a `/dev/*` path through it. Each call gets its own output cap:
    /// one file may be up to `CopyLimits.maxFileBytes`, while the run map is
    /// bounded far lower.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NTFSCopyToolRunner? {
        guard let chain = NTFSCopyToolLocator.locate(environment: environment) else { return nil }
        let volume = ProcessRunner(
            policy: .inspect,
            timeout: volumeTimeout,
            outputLimit: ProcessRunner.defaultOutputLimit
        )
        let listing = ProcessRunner(
            policy: .inspect,
            timeout: listingTimeout,
            outputLimit: 4_194_304
        )
        let cat = ProcessRunner(
            policy: .inspect,
            timeout: catTimeout,
            outputLimit: Int(CopyLimits.maxFileBytes)
        )
        let cluster = ProcessRunner(
            policy: .inspect,
            timeout: clusterTimeout,
            outputLimit: clusterOutputLimit
        )
        return NTFSCopyToolRunner(
            toolchain: chain,
            volumeExecutor: volume,
            listingExecutor: listing,
            catExecutor: cat,
            clusterExecutor: cluster
        )
    }
}
