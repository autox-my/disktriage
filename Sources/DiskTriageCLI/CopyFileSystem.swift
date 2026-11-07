import Foundation

/// The filesystem seam for `copy`. It extends `inspect`'s read/write seam with
/// directory creation and a whole-file write, so the command's only writes can
/// be redirected to a test double or a corrupting writer.
public protocol CopyFileSystem: InspectFileSystem {
    func isDirectory(_ path: String) -> Bool
    func createDirectory(_ path: String) throws
    func writeFile(_ data: Data, to path: String) throws
}

/// The live implementation. The read/extract path is `LiveInspectFileSystem`;
/// only the three copy-specific operations are new.
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
}
