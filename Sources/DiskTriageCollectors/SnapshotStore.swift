import CryptoKit
import Foundation
import DiskTriageCore

/// The file-system seam for `SnapshotStore`, so a write failure is a testable
/// outcome rather than a crashed process. The real implementation is the only
/// code here that touches the disk.
public protocol HistoryFileSystem: Sendable {
    func createDirectory(at url: URL, permissions: Int) throws
    func contentsOfDirectory(at url: URL) throws -> [String]
    func readData(at url: URL) throws -> Data
    /// Writes temp-then-renames in the destination directory, so a crash never
    /// leaves a half-written snapshot that could be read as a real one.
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func permissions(at url: URL) throws -> Int
}

public struct RealHistoryFileSystem: HistoryFileSystem {
    public init() {}

    public func createDirectory(at url: URL, permissions: Int) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public func contentsOfDirectory(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: temporary.path
            )
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func permissions(at url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}

/// What `loadPrior` found, plus a note for every file it had to skip.
public struct PriorSnapshot: Equatable, Sendable {
    public let record: SnapshotRecord?
    public let notes: [String]

    public init(record: SnapshotRecord?, notes: [String]) {
        self.record = record
        self.notes = notes
    }
}

public enum SnapshotSaveOutcome: Equatable, Sendable {
    case written(URL)
    case skipped(String)
    case failed(String)
}

/// The store seam the CLI uses, so a test can drive the no-write and
/// failed-write paths without a real directory.
public protocol SnapshotStoring: Sendable {
    func loadPrior(key: String, before: Date) -> PriorSnapshot
    func save(_ record: SnapshotRecord) -> SnapshotSaveOutcome
}

/// The local SMART snapshot store (diskdoctor.md §4).
///
/// Layout: `~/Library/Application Support/disktriage/history/<sha256>/<ms>-<uuid>.json`,
/// one JSON file per snapshot. A directory per device key is what makes the cap
/// and the "foreign device" check simple; one file per snapshot plus a
/// temp-then-rename write is the crash-safe choice — an interrupted append-only
/// JSONL would leave a half-line that a later read must special-case, while a
/// half-written snapshot file simply fails to decode and is skipped with a
/// note. The directory is 0700 and each file 0600.
public struct SnapshotStore: SnapshotStoring, Sendable {
    /// The cap per device: the newest 50 snapshots, oldest trimmed on write.
    public static let maximumSnapshotsPerDevice = 50

    public let directory: URL
    private let fileSystem: any HistoryFileSystem

    public init(directory: URL, fileSystem: any HistoryFileSystem = RealHistoryFileSystem()) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    /// `~/Library/Application Support/disktriage/history/` (diskdoctor.md §4).
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/disktriage/history", isDirectory: true)
    }

    /// `--history-dir` wins over `DISKTRIAGE_HISTORY_DIR`, which wins over the
    /// documented default. Pure so the precedence is tested, not assumed.
    public static func resolveDirectory(
        flag: String?,
        environment: [String: String],
        fallback: URL
    ) -> URL {
        if let flag, !flag.isEmpty {
            return URL(fileURLWithPath: flag)
        }
        if let value = environment["DISKTRIAGE_HISTORY_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return fallback
    }

    /// The full SHA-256 hex of the serial. Never truncated: the full hash is
    /// the directory name, and the raw serial is never written anywhere.
    public static func key(forSerial serial: String) -> String {
        SHA256.hash(data: Data(serial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func deviceDirectory(forKey key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: true)
    }

    public func loadPrior(key: String, before date: Date) -> PriorSnapshot {
        guard Self.isValidKey(key) else {
            return PriorSnapshot(record: nil, notes: ["invalid device key; no snapshot read"])
        }
        let deviceDirectory = deviceDirectory(forKey: key)
        guard fileSystem.fileExists(at: deviceDirectory) else {
            return PriorSnapshot(record: nil, notes: [])
        }

        let names: [String]
        do {
            names = try fileSystem.contentsOfDirectory(at: deviceDirectory)
        } catch {
            return PriorSnapshot(
                record: nil,
                notes: ["cannot list \(deviceDirectory.lastPathComponent): \(error.localizedDescription)"]
            )
        }

        var records: [SnapshotRecord] = []
        var notes: [String] = []
        for name in names.sorted() {
            guard name.hasSuffix(".json") else {
                notes.append("skipped \(name): not a snapshot file")
                continue
            }
            let url = deviceDirectory.appendingPathComponent(name)
            do {
                let data = try fileSystem.readData(at: url)
                let record = try JSONDecoder.disktriage().decode(SnapshotRecord.self, from: data)
                guard record.schemaVersion == SnapshotRecord.currentSchemaVersion else {
                    notes.append("skipped \(name): unknown schema version \(record.schemaVersion)")
                    continue
                }
                guard record.deviceKey == key else {
                    notes.append("skipped \(name): device key mismatch")
                    continue
                }
                records.append(record)
            } catch {
                notes.append("skipped \(name): unreadable or not a snapshot")
            }
        }

        return PriorSnapshot(
            record: SnapshotHistory.mostRecentPrior(records, forKey: key, before: date),
            notes: notes
        )
    }

    public func save(_ record: SnapshotRecord) -> SnapshotSaveOutcome {
        guard record.schemaVersion == SnapshotRecord.currentSchemaVersion else {
            return .skipped("schema version \(record.schemaVersion) is not supported")
        }
        guard record.smartStatus == .ok else {
            return .skipped("SMART \(record.smartStatus.rawValue) is not a measurement")
        }
        guard Self.isValidKey(record.deviceKey) else {
            return .skipped("invalid device key")
        }

        let deviceDirectory = deviceDirectory(forKey: record.deviceKey)
        do {
            try fileSystem.createDirectory(at: directory, permissions: 0o700)
            try fileSystem.createDirectory(at: deviceDirectory, permissions: 0o700)
            let data = try JSONEncoder.disktriage().encode(record)
            let url = deviceDirectory.appendingPathComponent(Self.fileName(for: record))
            try fileSystem.writeAtomically(data, to: url, permissions: 0o600)
            trim(record.deviceKey)
            return .written(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func trim(_ key: String) {
        let deviceDirectory = deviceDirectory(forKey: key)
        guard let names = try? fileSystem.contentsOfDirectory(at: deviceDirectory) else { return }
        let snapshots = names.filter { $0.hasSuffix(".json") }.sorted()
        guard snapshots.count > Self.maximumSnapshotsPerDevice else { return }
        let excess = snapshots.count - Self.maximumSnapshotsPerDevice
        for name in snapshots.prefix(excess) {
            try? fileSystem.removeItem(at: deviceDirectory.appendingPathComponent(name))
        }
    }

    private static func fileName(for record: SnapshotRecord) -> String {
        let milliseconds = Int64((record.recordedAt.timeIntervalSince1970 * 1_000).rounded())
        let stamp = String(format: "%013lld", milliseconds)
        return "\(stamp)-\(UUID().uuidString).json"
    }

    /// A device key is the full 64-character lowercase hex SHA-256.
    static func isValidKey(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy { $0.isHexDigit }
    }
}
