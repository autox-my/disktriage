import Foundation

/// The filesystem seam for `inspect`. The live implementation is the only
/// place that opens a file; the command below is driven through this protocol,
/// so the tests can supply real temporary images without a device.
public protocol InspectFileSystem: Sendable {
    func exists(_ path: String) -> Bool
    func isRegularFile(_ path: String) -> Bool
    func size(_ path: String) throws -> Int64
    func read(_ path: String, offset: Int64, count: Int) throws -> Data
    /// A byte-for-byte, offset-limited copy (the `dd skip=/count=` equivalent).
    /// Returns the number of bytes written; a short source is a short extract,
    /// never an invented tail.
    @discardableResult
    func extract(from source: String, offset: Int64, length: Int64, to destination: String) throws -> Int64
    func copy(from source: String, to destination: String) throws
    /// Writes exactly `data.count` bytes at `offset` and does not truncate or
    /// extend the rest of the file (`conv=notrunc` semantics).
    func write(_ data: Data, to path: String, offset: Int64) throws
    func remove(_ path: String)
    func temporaryFile() -> String
}

public struct LiveInspectFileSystem: InspectFileSystem {
    public init() {}

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isRegularFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    public func size(_ path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber else {
            throw InspectFileSystemError("cannot read the size of \(path)")
        }
        return size.int64Value
    }

    public func read(_ path: String, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return (try handle.read(upToCount: count)) ?? Data()
    }

    @discardableResult
    public func extract(from source: String, offset: Int64, length: Int64, to destination: String) throws -> Int64 {
        guard length > 0 else { return 0 }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(max(0, offset)))

        try? FileManager.default.removeItem(atPath: destination)
        guard FileManager.default.createFile(atPath: destination, contents: nil) else {
            throw InspectFileSystemError("cannot create the working file \(destination)")
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
        defer { try? output.close() }

        var written: Int64 = 0
        let chunk = 1_048_576
        while written < length {
            let want = Int(min(Int64(chunk), length - written))
            let data = try input.read(upToCount: want) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            written += Int64(data.count)
        }
        return written
    }

    public func copy(from source: String, to destination: String) throws {
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    public func write(_ data: Data, to path: String, offset: Int64) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        try handle.write(contentsOf: data)
    }

    public func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func temporaryFile() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("disktriage-inspect-\(UUID().uuidString).img").path
    }
}

public struct InspectFileSystemError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
