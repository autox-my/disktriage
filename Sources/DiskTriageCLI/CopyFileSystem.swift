import Foundation
import Darwin

/// A destination file being written incrementally. `copy` writes into a
/// temporary name in the destination directory, reads those bytes back, and
/// only then calls `commit` (fsync + atomic install under the final name,
/// never replacing an existing file). `abort` removes the temporary file on
/// every failure, timeout and cap.
public protocol CopyFileWriter: AnyObject {
    /// The temporary file's absolute path, used for the read-back.
    var temporaryPath: String { get }
    func write(_ data: Data) throws
    /// Flush the bytes to stable storage before the read-back.
    func sync() throws
    /// Install the temporary file under its final name without overwriting.
    func commit() throws
    /// Delete the temporary file. Safe to call more than once, and a no-op
    /// after a successful commit.
    func abort()
}

public enum CopyFileWriterError: Error, CustomStringConvertible, Sendable {
    case targetExists(String)
    case installFailed(String, Int32)

    public var description: String {
        switch self {
        case .targetExists(let path):
            return "\(path) already exists; copy never overwrites a file"
        case .installFailed(let path, let code):
            return "cannot install \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// The filesystem seam for `copy`. It extends `inspect`'s read/write seam with
/// directory creation, a streamed writer and a bounded read-back, so the
/// command's only writes can be redirected to a test double or a corrupting
/// writer.
public protocol CopyFileSystem: InspectFileSystem {
    func isDirectory(_ path: String) -> Bool
    func createDirectory(_ path: String) throws
    /// Write a whole file at once. Used for the manifest and summary, which are
    /// small command records, never copied file data.
    func writeFile(_ data: Data, to path: String) throws
    /// A streamed writer for copied file data. The data goes to a temporary
    /// name in `path`'s directory and is installed under `path` on `commit`.
    func makeWriter(to path: String) throws -> any CopyFileWriter
    /// Read a file back in bounded chunks. Returns the byte count.
    @discardableResult
    func readChunks(_ path: String, chunkSize: Int, consume: (Data) throws -> Void) throws -> Int64
}

/// The live implementation. The read/extract path is `LiveInspectFileSystem`;
/// the copy-specific operations are new.
public struct LiveCopyFileSystem: CopyFileSystem {
    private let base: LiveInspectFileSystem

    public init() {
        self.base = LiveInspectFileSystem()
    }

    public func exists(_ path: String) -> Bool { base.exists(path) }
    public func isRegularFile(_ path: String) -> Bool { base.isRegularFile(path) }
    public func size(_ path: String) throws -> Int64 { try base.size(path) }
    public func read(_ path: String, offset: Int64, count: Int) throws -> Data {
        try base.read(path, offset: offset, count: count)
    }

    @discardableResult
    public func extract(from source: String, offset: Int64, length: Int64, to destination: String) throws -> Int64 {
        try base.extract(from: source, offset: offset, length: length, to: destination)
    }

    public func copy(from source: String, to destination: String) throws {
        try base.copy(from: source, to: destination)
    }

    public func write(_ data: Data, to path: String, offset: Int64) throws {
        try base.write(data, to: path, offset: offset)
    }

    public func remove(_ path: String) { base.remove(path) }
    public func temporaryFile() -> String { base.temporaryFile() }

    public func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path),
            withIntermediateDirectories: true
        )
    }

    public func writeFile(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    public func makeWriter(to path: String) throws -> any CopyFileWriter {
        try LiveCopyFileWriter(target: path)
    }

    @discardableResult
    public func readChunks(
        _ path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var total: Int64 = 0
        let capacity = max(1, chunkSize)
        while let data = try handle.read(upToCount: capacity), !data.isEmpty {
            try consume(data)
            total += Int64(data.count)
        }
        return total
    }
}

/// Writes to `.<name>.disktriage-partial.<uuid>` beside the target, fsyncs, and
/// installs with `link`+`unlink`, which fails rather than replacing an
/// existing file. A crash leaves only a named partial file, never a plausible
/// final one.
final class LiveCopyFileWriter: CopyFileWriter {
    let temporaryPath: String
    private let target: String
    private var descriptor: Int32
    private var committed = false

    init(target: String) throws {
        self.target = target
        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        self.temporaryPath = directory + "/." + name + ".disktriage-partial." + UUID().uuidString
        let fd = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw InspectFileSystemError(
                "cannot create a temporary file beside \(target): \(String(cString: strerror(errno)))"
            )
        }
        self.descriptor = fd
    }

    deinit {
        if !committed {
            if descriptor >= 0 { close(descriptor) }
            unlink(temporaryPath)
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes -> Int in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw InspectFileSystemError(
                    "cannot write \(temporaryPath): \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    func sync() throws {
        guard descriptor >= 0 else {
            throw InspectFileSystemError("the temporary file for \(target) is already closed")
        }
        guard fsync(descriptor) == 0 else {
            throw InspectFileSystemError(
                "cannot flush \(temporaryPath): \(String(cString: strerror(errno)))"
            )
        }
    }

    func commit() throws {
        guard descriptor >= 0 else {
            throw InspectFileSystemError("the temporary file for \(target) is already closed")
        }
        guard fsync(descriptor) == 0 else {
            throw InspectFileSystemError(
                "cannot flush \(temporaryPath): \(String(cString: strerror(errno)))"
            )
        }
        close(descriptor)
        descriptor = -1

        // link(2) is an atomic no-replace install: EEXIST means a file appeared
        // at the destination, so the copy refuses instead of overwriting it.
        guard link(temporaryPath, target) == 0 else {
            let code = errno
            unlink(temporaryPath)
            if code == EEXIST {
                throw CopyFileWriterError.targetExists(target)
            }
            throw CopyFileWriterError.installFailed(temporaryPath, code)
        }
        unlink(temporaryPath)
        committed = true

        // Best effort: make the directory entry durable too.
        let directory = (target as NSString).deletingLastPathComponent
        let directoryFD = open(directory, O_RDONLY)
        if directoryFD >= 0 {
            fsync(directoryFD)
            close(directoryFD)
        }
    }

    func abort() {
        guard !committed else { return }
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(temporaryPath)
    }
}
