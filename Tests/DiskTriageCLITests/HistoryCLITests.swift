import Foundation
import Testing
import DiskTriageTestSupport
import DiskTriageCore
import DiskTriageCollectors
import DiskTriageCLI

/// End-to-end history behaviour through the library seam: the store is a real
/// directory under the system temp dir, the collectors are scripted, and the
/// only hand-invented data is the SMART attribute table (never a committed
/// prior-history fixture).
struct HistoryCLITests {
    private let temp = TempDir()

    private static let serial = "SYNTH0000ABCD"

    private func makeTempDirectory() throws -> URL {
        URL(fileURLWithPath: try temp.makeDirectory("history"))
    }

    private func smartJSON(reallocated: Int) -> String {
        """
        {"smartctl":{"exit_status":0},
         "smart_status":{"passed":true},
         "ata_smart_attributes":{"table":[
           {"id":5,"raw":{"value":\(reallocated)}},
           {"id":197,"raw":{"value":0}},
           {"id":198,"raw":{"value":0}}
         ]}}
        """
    }

    private func historyExecutor(
        reallocated: Int,
        info: String = "diskutil-info-usb-synthetic-serial.plist"
    ) -> CLIExecutor {
        CLIExecutor { command in
            switch command {
            case .diskutilInfo:
                return .ok(fixtureText(info))
            case .ioregStatistics:
                return .ok(fixtureText("ioreg-internal-driver.txt"))
            case .ioregMedia:
                return .ok(fixtureText("ioreg-iomedia-internal.txt"))
            case .logShow:
                return .ok(fixtureText("kernel-log-healthy-compact.txt"))
            case .smartctl:
                return .ok(self.smartJSON(reallocated: reallocated))
            default:
                return .ok("")
            }
        }
    }

    // REQ-0150, REQ-0151, REQ-0159
    @Test("REQ0150_REQ0151_REQ0159 a store-written prior snapshot turns a rising reallocated count into exit 10")
    func REQ0150_REQ0151_REQ0159_storeWrittenPriorDrivesTheTrendRule() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = ["triage", "disk8", "--history-dir", root.path]

        let first = run(
            arguments: arguments,
            executor: historyExecutor(reallocated: 5),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        #expect(first.exitCode == 0, "stable reallocated=5 with no history is a low warning")
        #expect(first.stderr.contains("history: first sight"), "first sight is stated: \(first.stderr)")

        let key = SnapshotStore.key(forSerial: Self.serial)
        let directory = root.appendingPathComponent(key, isDirectory: true)
        let afterFirst = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        #expect(afterFirst.count == 1, "the first run wrote one snapshot through the store")

        let second = run(
            arguments: arguments,
            executor: historyExecutor(reallocated: 8),
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        #expect(second.exitCode == 10, "8 > 5 is rising reallocated, so MEDIA and exit 10")
        #expect(second.stderr.contains("history: used"), "history was used: \(second.stderr)")
        #expect(second.stdout.contains("confidence: MEDIUM"),
                "the prior snapshot is what promotes MEDIA from low to medium: \(second.stdout)")
        #expect(second.stdout.contains("reallocated"), "the current count is rendered")
    }

    // REQ-0159
    @Test("REQ0009_REQ0159 --no-history neither reads nor writes the store")
    func REQ0009_REQ0159_noHistoryDisablesTheStore() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = run(
            arguments: ["triage", "disk8", "--history-dir", root.path, "--no-history"],
            executor: historyExecutor(reallocated: 8),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        #expect(result.exitCode == 0, "without history, reallocated=8 is a stable low warning")
        #expect(result.stderr.contains("history: disabled"), "the run says why: \(result.stderr)")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(contents.isEmpty, "nothing was written when history is disabled")
    }

    // REQ-0155
    @Test("REQ0017_REQ0155 a device with no serial has no key: no read, no write, and a reason")
    func REQ0017_REQ0155_noSerialMeansNoKey() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = SpyHistoryStore()

        let result = run(
            arguments: ["triage", "disk8", "--history-dir", root.path],
            executor: historyExecutor(reallocated: 8, info: "diskutil-info-usb-unknown.plist"),
            now: { Date(timeIntervalSince1970: 1_000) },
            historyStore: spy
        )

        #expect(result.stderr.contains("no serial"), "the reason is on stderr: \(result.stderr)")
        #expect(spy.loads == 0, "no history was read without a key")
        #expect(spy.saves == 0, "no snapshot was written without a key")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(contents.isEmpty)
    }

    // REQ-0160
    @Test("REQ0160 a failed snapshot write changes neither the verdict nor the exit code")
    func REQ0160_writeFailureLeavesTheVerdictAlone() throws {
        let spy = SpyHistoryStore()
        spy.outcome = .failed("disk is full")

        let result = run(
            arguments: ["triage", "disk8", "--history-dir", "/tmp/unused-history"],
            executor: historyExecutor(reallocated: 8),
            now: { Date(timeIntervalSince1970: 1_000) },
            historyStore: spy
        )

        #expect(result.exitCode == 0, "the verdict is still the stable-reallocated verdict")
        #expect(spy.saves == 1, "the write was attempted")
        #expect(result.stderr.contains("disk is full"), "the failure is noted on stderr")
        #expect(result.stderr.contains("verdict is unchanged"), "the exit code does not change")
    }

    // REQ-0159
    @Test("REQ0042_REQ0159 triage --from never reads or writes the store")
    func REQ0042_REQ0159_recordedSignalSetNeverTouchesTheStore() {
        let spy = SpyHistoryStore()

        let result = run(
            arguments: ["triage", "--from", fixturePath("minah.json")],
            historyStore: spy
        )

        #expect(result.exitCode == 10, "the recorded verdict is unchanged")
        #expect(spy.loads == 0, "no prior snapshot was read for a recorded set")
        #expect(spy.saves == 0, "no snapshot was written for a recorded set")
    }

    // REQ-0158
    @Test("REQ0158 a corrupt snapshot is skipped with a note and never becomes a number")
    func REQ0158_corruptSnapshotIsSkippedWithANote() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(directory: root)
        let directory = store.deviceDirectory(forKey: SnapshotStore.key(forSerial: Self.serial))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let result = run(
            arguments: ["triage", "disk8", "--history-dir", root.path],
            executor: historyExecutor(reallocated: 8),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        #expect(result.exitCode == 0, "a corrupt file does not invent a rising trend")
        #expect(result.stderr.contains("skipped"), "the unusable file is named: \(result.stderr)")
        #expect(result.stderr.contains("broken.json"), "the note names the file")
        #expect(result.stdout.contains("reallocated"), "the current measurement still renders")
        #expect(result.stdout.contains("confidence: LOW"), "without history the same count stays a low warning")
        #expect(!result.stdout.contains("confidence: MEDIUM"), "no trend claim came from a corrupt file")
    }

    @Test("REQ0155 --history-dir without a path is a usage error")
    func REQ0155_historyDirNeedsAValue() {
        let result = run(arguments: ["triage", "disk8", "--history-dir"])
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("--history-dir"))
    }

    /// REQ-0159 also covers the read-only side-effect rule: `image` runs an
    /// internal triage attempt, and that attempt must not touch history.
    @Test("image's internal triage attempt never reads or writes the store")
    func imageTriageAttemptDoesNotTouchTheStore() {
        let spy = SpyHistoryStore()
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )

        let result = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-serial", "ABCD"],
            executor: historyExecutor(reallocated: 8),
            destinationProbe: FakeImageProbe(facts: facts),
            historyStore: spy
        )

        #expect(result.exitCode == 0, "the image plan still forms")
        #expect(spy.loads == 0, "image's triage attempt did not read history")
        #expect(spy.saves == 0, "image's triage attempt did not write a snapshot")
    }
}

final class SpyHistoryStore: SnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLoads = 0
    private var recordedSaves = 0

    var prior = PriorSnapshot(record: nil, notes: [])
    var outcome: SnapshotSaveOutcome = .skipped("not used")

    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedLoads
    }

    var saves: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedSaves
    }

    func loadPrior(key: String, before: Date) -> PriorSnapshot {
        lock.lock()
        recordedLoads += 1
        lock.unlock()
        return prior
    }

    func save(_ record: SnapshotRecord) -> SnapshotSaveOutcome {
        lock.lock()
        recordedSaves += 1
        lock.unlock()
        return outcome
    }
}

private func fixtureText(_ name: String) -> String {
    (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
}
