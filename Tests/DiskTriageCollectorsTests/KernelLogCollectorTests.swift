import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// The unified-log collector is a pure parse over recorded `log show` output;
/// the query is built for one BSD disk and the default window is the plan's 6 h.
struct KernelLogCollectorTests {

    @Test("the recorded Phase C log becomes two events for disk8")
    func theRecordedPhaseCLogBecomesEvents() throws {
        let executor = RecordingExecutor([
            .logShow(last: "6h", predicate: ""): .ok(try collectorFixture("kernel-log-medium-errors.ndjson")),
        ])
        let collection = KernelLogCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .ok, "log show answered")
        #expect(collection.windowHours == 6, "the default window is 6 h")
        #expect(collection.events.count == 2, "one event per read size")
        #expect(collection.events.allSatisfy { $0.lba == 2048 }, "decimal LBA 2048")

        let command = try #require(executor.commands.first, "one query")
        guard case .logShow(let last, let predicate) = command else {
            Issue.record("expected a log show command, got \(command)")
            return
        }
        #expect(last == "6h", "the window reaches the command")
        #expect(predicate.contains("disk8"), "the predicate is built for the disk: \(predicate)")
        #expect(predicate.contains("medium error"), "the predicate keeps the medium-error family")
    }

    @Test("events attributed to another disk are dropped while the section stays ok")
    func anotherDisksEventsAreDropped() throws {
        let executor = RecordingExecutor([
            .logShow(last: "6h", predicate: ""): .ok(try collectorFixture("kernel-log-medium-errors.ndjson")),
        ])
        let collection = KernelLogCollector(executor: executor).collect(bsd: "disk4")

        #expect(collection.status == .ok, "the query itself succeeded")
        #expect(collection.events.isEmpty, "a measured empty event list, not an absent signal")
    }

    @Test("the --log-window option reaches log show and window_hours")
    func theWindowOptionReachesTheQuery() throws {
        let executor = RecordingExecutor([
            .logShow(last: "24h", predicate: ""): .ok(try collectorFixture("kernel-log-healthy-compact.txt")),
        ])
        let collection = KernelLogCollector(executor: executor).collect(bsd: "disk8", window: "24h")

        #expect(collection.status == .ok, "status")
        #expect(collection.windowHours == 24, "window_hours")
        #expect(collection.events.isEmpty, "a healthy log is an ok empty section")
    }

    @Test("a timeout is a timeout, not zero events")
    func aTimeoutIsATimeout() {
        let timeout = RecordingExecutor([.logShow(last: "6h", predicate: ""): .timeout()])
        let failed = KernelLogCollector(executor: timeout).collect(bsd: "disk8")
        #expect(failed.status == .timeout, "status")
        #expect(failed.reason?.isEmpty == false, "reason")
    }

    @Test("an unparseable window is an error, never a whole-log query")
    func anInvalidWindowIsAnError() {
        let collection = KernelLogCollector(executor: RecordingExecutor([:]))
            .collect(bsd: "disk8", window: "all-of-it")
        #expect(collection.status == .error, "status")
        #expect(collection.windowHours == nil, "no window was measured")
    }
}
