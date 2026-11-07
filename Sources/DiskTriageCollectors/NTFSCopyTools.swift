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
    /// `ntfscat <image> <volume-path>`: binary file data, buffered. Kept for
    /// the recorded-output seam and the streaming fallback; `copy` itself uses
    /// `catFileStreaming` so a file is never held whole in memory.
    func catFile(image: String, path: String) -> CommandDataResult
    /// `ntfscat` with stdout handed to `consume` in bounded chunks.
    func catFileStreaming(
        image: String,
        path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) -> CommandStreamResult
    /// `ntfscluster -c 0-(lastCluster) -v`: every inode's LCN runs in one pass.
    func clusterRuns(image: String, lastCluster: Int64) -> CollectorResult
}

public extension NTFSCopyToolRunning {
    /// Scripted tools only have whole `Data`; split it into bounded chunks so
    /// the copy loop is still driven one chunk at a time. A real runner
    /// overrides this with `ProcessRunner.stream` and never buffers stdout.
    func catFileStreaming(
        image: String,
        path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) -> CommandStreamResult {
        streamBuffered(
            catFile(image: image, path: path),
            chunkSize: chunkSize,
            consume: consume
        )
    }
}

/// The fallback for an executor that is not a `CommandStreaming`: split an
/// already-recorded result into chunks. Never used by the live runner.
public func streamBuffered(
    _ result: CommandDataResult,
    chunkSize: Int,
    consume: (Data) throws -> Void
) -> CommandStreamResult {
    guard result.outcome == .ok else {
        return CommandStreamResult(
            outcome: result.outcome,
            exitCode: result.exitCode,
            stderr: result.stderr,
            stderrTruncated: result.stderrTruncated,
            bytesRead: 0,
            durationMs: result.durationMs,
            policyViolation: result.policyViolation
        )
    }
    if result.stdoutTruncated {
        return CommandStreamResult(
            outcome: .error,
            exitCode: result.exitCode,
            stderr: result.stderr,
            stderrTruncated: result.stderrTruncated,
            bytesRead: 0,
            durationMs: result.durationMs,
            policyViolation: result.policyViolation
        )
    }
    let capacity = max(1, chunkSize)
    var offset = 0
    var bytes: Int64 = 0
    do {
        while offset < result.stdout.count {
            let end = min(offset + capacity, result.stdout.count)
            let chunk = result.stdout.subdata(in: offset..<end)
            try consume(chunk)
            bytes += Int64(chunk.count)
            offset = end
        }
    } catch {
        return CommandStreamResult(
            outcome: .error,
            exitCode: result.exitCode,
            stderr: result.stderr,
            stderrTruncated: result.stderrTruncated,
            bytesRead: bytes,
            durationMs: result.durationMs,
            policyViolation: result.policyViolation,
            consumerFailed: true,
            consumerError: String(describing: error)
        )
    }
    return CommandStreamResult(
        outcome: .ok,
        exitCode: result.exitCode,
        stderr: result.stderr,
        stderrTruncated: result.stderrTruncated,
        bytesRead: bytes,
        durationMs: result.durationMs,
        policyViolation: result.policyViolation
    )
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

    public func catFileStreaming(
        image: String,
        path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) -> CommandStreamResult {
        let command = TriageCommand.ntfsTool(path: toolchain.ntfscat, arguments: [image, path])
        if let streaming = catExecutor as? any CommandStreaming {
            return streaming.stream(
                command,
                timeout: Self.catTimeout,
                chunkSize: chunkSize,
                consume: consume
            )
        }
        return streamBuffered(
            catExecutor.runData(command, timeout: Self.catTimeout),
            chunkSize: chunkSize,
            consume: consume
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
    /// writer or a `/dev/*` path through it. stdout for `ntfscat` is streamed
    /// in chunks and is not bounded by `outputLimit`; that cap applies to
    /// stderr (and to the buffered fallback), while the run map keeps its own
    /// lower bound.
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
            outputLimit: ProcessRunner.defaultOutputLimit
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
