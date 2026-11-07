import Foundation
import Testing
import DiskTriageTestSupport
@testable import DiskTriageCollectors
import DiskTriageCore

/// The store half of the local snapshot history (diskdoctor.md §4): one JSON
/// file per snapshot under a directory named by the FULL SHA-256 of the serial,
/// written temp-then-rename, capped at 50 per device.
///
/// The store is driven against a real temporary directory here; the only fake
/// is the file-system seam used to prove a write failure is reported, not
/// thrown.
struct SnapshotStoreTests {
    private let temp = TempDir()

    private static let serial = "SYNTH0000ABCD"
    // The independent SHA-256 of the serial: `printf 'SYNTH0000ABCD' | shasum -a 256`.
    private static let key = "140a7381765287afbe4ee54904e08feabe9024b26a0a769284e63f5a81ee1b57"

    private func makeTempDirectory() throws -> URL {
        URL(fileURLWithPath: try temp.makeDirectory("history"))
    }

    private func record(
        _ seconds: TimeInterval,
        key: String = SnapshotStoreTests.key,
        status: SignalStatus = .ok,
        reallocated: Int? = 5
    ) -> SnapshotRecord {
        SnapshotRecord(
            schemaVersion: SnapshotRecord.currentSchemaVersion,
            recordedAt: Date(timeIntervalSince1970: seconds),
            deviceKey: key,
            smartStatus: status,
            pending: 0,
            reallocated: reallocated,
            uncorrectable: 0
        )
    }

    // REQ-0155
    @Test("REQ0155 --history-dir wins over DISKTRIAGE_HISTORY_DIR, which wins over the default")
    func REQ0155_directoryPrecedence() {
        let fallback = URL(fileURLWithPath: "/fallback/history")

        #expect(
            SnapshotStore.resolveDirectory(
                flag: "/flag/history",
                environment: ["DISKTRIAGE_HISTORY_DIR": "/env/history"],
                fallback: fallback
            ).path == "/flag/history",
            "the flag wins"
        )
        #expect(
            SnapshotStore.resolveDirectory(
                flag: nil,
                environment: ["DISKTRIAGE_HISTORY_DIR": "/env/history"],
                fallback: fallback
            ).path == "/env/history",
            "the environment variable overrides the default"
        )
        #expect(
            SnapshotStore.resolveDirectory(flag: nil, environment: [:], fallback: fallback).path == fallback.path,
            "the default is last"
        )
    }

    // REQ-0156
    @Test("REQ0017_REQ0156 the device key is the full SHA-256 of the serial, never the BSD name or raw serial")
    func REQ0017_REQ0156_keyIsTheFullSha256OfTheSerial() {
        #expect(SnapshotStore.key(forSerial: Self.serial) == Self.key)
        #expect(SnapshotStore.key(forSerial: Self.serial).count == 64, "full hash, never truncated")
    }

    // REQ-0156
    @Test("REQ0156 a saved snapshot lives under the hashed key and contains no raw serial")
    func REQ0156_snapshotOnDiskUsesTheHashOnly() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)

        let outcome = store.save(record(100))
        guard case .written = outcome else {
            Issue.record("the snapshot was not written: \(outcome)")
            return
        }

        let deviceDirectory = store.deviceDirectory(forKey: Self.key)
        #expect(deviceDirectory.lastPathComponent == Self.key, "the full hash names the device directory")
        #expect(FileManager.default.fileExists(atPath: deviceDirectory.path))

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var sawFile = false
        while let url = enumerator?.nextObject() as? URL {
            if url.hasDirectoryPath { continue }
            sawFile = true
            #expect(!url.path.contains(Self.serial), "the raw serial is never in a path")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains(Self.serial), "the raw serial is never in a file")
        }
        #expect(sawFile, "one snapshot file exists")
    }

    // REQ-0155, REQ-0156
    @Test("REQ0155_REQ0156 the directory is 0700, the snapshot file 0600, and the default path is documented")
    func REQ0155_permissionsAndDefaultPath() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)
        _ = store.save(record(100))

        let rootPermissions = try FileManager.default
            .attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber
        #expect(rootPermissions?.intValue == 0o700, "the history root is owner-only")

        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: store.deviceDirectory(forKey: Self.key).path)[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.intValue == 0o700, "the per-device directory is owner-only")

        let files = try FileManager.default.contentsOfDirectory(atPath: store.deviceDirectory(forKey: Self.key).path)
        let file = try #require(files.first)
        let filePermissions = try FileManager.default
            .attributesOfItem(atPath: store.deviceDirectory(forKey: Self.key).appendingPathComponent(file).path)[.posixPermissions] as? NSNumber
        #expect(filePermissions?.intValue == 0o600, "the snapshot file is owner-only")

        #expect(
            SnapshotStore.defaultDirectory().path.hasSuffix(
                "/Library/Application Support/disktriage/history"
            ),
            "the default path from diskdoctor.md §4"
        )
    }

    // REQ-0150
    @Test("REQ0150 the store returns the most recent prior snapshot for a key")
    func REQ0150_loadPriorReturnsTheMostRecent() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)

        _ = store.save(record(100, reallocated: 3))
        _ = store.save(record(200, reallocated: 5))

        let prior = store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 300))
        #expect(prior.notes.isEmpty)
        #expect(prior.record?.reallocated == 5, "the latest prior snapshot")
        #expect(SnapshotHistory.history(from: prior.record, forKey: Self.key)?.reallocated == 5)
    }

    // REQ-0151
    @Test("REQ0151 an empty or future-only store is first sight")
    func REQ0151_noPriorIsFirstSight() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)

        #expect(store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 300)).record == nil)

        _ = store.save(record(400))
        #expect(store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 300)).record == nil)
        #expect(store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 500)).record != nil)
    }

    // REQ-0152
    @Test("REQ0152 the store does not turn a non-ok snapshot into history")
    func REQ0152_nonOkSnapshotYieldsNoHistory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)

        // The store refuses to write it; a hand-placed file is read and still
        // rejected by the history rule (absent is never a zero).
        let directory = store.deviceDirectory(forKey: Self.key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let denied = record(200, status: .denied, reallocated: nil)
        try JSONEncoder.disktriage().encode(denied).write(to: directory.appendingPathComponent("200-denied.json"))

        let prior = store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 300))
        #expect(prior.record?.smartStatus == .denied)
        #expect(SnapshotHistory.history(from: prior.record, forKey: Self.key) == nil)
    }

    // REQ-0154
    @Test(
        "REQ0154 the store refuses a snapshot taken under a non-ok SMART status",
        arguments: [SignalStatus.denied, .timeout, .unsupported, .error]
    )
    func REQ0154_storeRefusesNonOkSnapshots(status: SignalStatus) throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)

        let outcome = store.save(record(100, status: status, reallocated: nil))
        guard case .skipped = outcome else {
            Issue.record("a \(status) snapshot must be skipped, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: store.deviceDirectory(forKey: Self.key).path))
    }

    // REQ-0153
    @Test("REQ0153 a snapshot for one key is never returned for another")
    func REQ0153_neverCrossesKeys() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)
        let otherKey = String(repeating: "b", count: 64)

        _ = store.save(record(100, key: otherKey))
        #expect(store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 300)).record == nil)
    }

    // REQ-0157
    @Test("REQ0157 at most the newest 50 snapshots per device are kept")
    func REQ0157_capsAtFiftyPerDevice() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)

        for index in 0..<55 {
            let outcome = store.save(record(TimeInterval(index), reallocated: index))
            guard case .written = outcome else {
                Issue.record("snapshot \(index) was not written: \(outcome)")
                return
            }
        }

        let directory = store.deviceDirectory(forKey: Self.key)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 50, "the cap is 50 files")

        var kept: [Int] = []
        for file in files {
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            let decoded = try JSONDecoder.disktriage().decode(SnapshotRecord.self, from: data)
            kept.append(decoded.reallocated ?? -1)
        }
        #expect(kept.sorted() == Array(5..<55), "the oldest five were dropped, not the newest")

        let prior = store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 1_000))
        #expect(prior.record?.reallocated == 54, "the newest snapshot survives")
    }

    // REQ-0158
    @Test("REQ0158 corrupt, unknown-schema and foreign-key files are skipped with a note")
    func REQ0158_skipsUnusableFilesWithANote() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)
        let directory = store.deviceDirectory(forKey: Self.key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder.disktriage()
        try encoder.encode(record(100, reallocated: 5)).write(to: directory.appendingPathComponent("100-valid.json"))
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("200-corrupt.json"))
        let oldSchema = SnapshotRecord(
            schemaVersion: 99,
            recordedAt: Date(timeIntervalSince1970: 250),
            deviceKey: Self.key,
            smartStatus: .ok,
            pending: 0,
            reallocated: 7,
            uncorrectable: 0
        )
        try encoder.encode(oldSchema).write(to: directory.appendingPathComponent("250-old-schema.json"))
        try encoder.encode(record(300, key: String(repeating: "b", count: 64), reallocated: 9))
            .write(to: directory.appendingPathComponent("300-foreign.json"))
        try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let prior = store.loadPrior(key: Self.key, before: Date(timeIntervalSince1970: 400))
        #expect(prior.record?.reallocated == 5, "the only usable snapshot is the one for this key and schema")
        #expect(prior.notes.count == 4, "corrupt, unknown schema, foreign key and a non-client file each earn a note")
        #expect(prior.notes.contains { $0.contains("corrupt.json") })
        #expect(prior.notes.contains { $0.contains("old-schema.json") })
        #expect(prior.notes.contains { $0.contains("foreign.json") })
        #expect(prior.notes.contains { $0.contains("notes.txt") })
        #expect(SnapshotHistory.history(from: prior.record, forKey: Self.key)?.reallocated == 5)
    }

    // REQ-0160
    @Test("REQ0160 a write failure is reported, never thrown")
    func REQ0160_writeFailureIsReported() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root, fileSystem: FailingHistoryFileSystem())

        let outcome = store.save(record(100))
        guard case .failed(let reason) = outcome else {
            Issue.record("expected a failed outcome, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }
}

private struct FailingHistoryFileSystem: HistoryFileSystem {
    func createDirectory(at url: URL, permissions: Int) throws {}
    func contentsOfDirectory(at url: URL) throws -> [String] { [] }
    func readData(at url: URL) throws -> Data { Data() }
    func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func removeItem(at url: URL) throws {}
    func fileExists(at url: URL) -> Bool { false }
    func permissions(at url: URL) throws -> Int { 0 }
}
