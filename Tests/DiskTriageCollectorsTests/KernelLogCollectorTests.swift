import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// The unified-log collector is a pure parse over recorded `log show` output.
/// The query is restricted to the kernel process because the old message-only
/// predicate was measured too slow on this Mac (see the collector's constants),
/// and the default window is 1 h.
struct KernelLogCollectorTests {

    @Test("the default query is the kernel I/O-error predicate at 1h")
    func theDefaultQueryIsTheKernelPredicateAtOneHour() throws {
        let executor = RecordingExecutor([
            .logShow(last: "1h", predicate: ""): .ok(try collectorFixture("kernel-log-medium-errors.ndjson")),
        ])
        let collection = KernelLogCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .ok, "log show answered")
        #expect(collection.windowHours == 1, "the default window is 1 h")

        let command = try #require(executor.commands.first, "one query")
        guard case .logShow(let last, let predicate) = command else {
            Issue.record("expected a log show command, got \(command)")
            return
        }
        #expect(last == "1h", "the default window reaches the command")
        #expect(
            predicate == #"process == "kernel" AND eventMessage CONTAINS[c] "I/O error""#,
            "the kernel predicate: \(predicate)"
        )
        #expect(predicate == KernelLogCollector.predicate, "the constant is what is queried")

        // The predicate cannot name a disk; the Phase C events must survive the
        // post-parse filter even though only the closing line carries a disk.
        #expect(collection.events.count == 2, "one event per read size")
        #expect(collection.events.allSatisfy { $0.lba == 2048 }, "decimal LBA 2048")
    }

    @Test("the hard timeout scales with the query window")
    func theTimeoutScalesWithTheWindow() {
        #expect(KernelLogCollector.timeoutSeconds(forWindowHours: 1) == 30, "1 h -> 30 s floor")
        #expect(KernelLogCollector.timeoutSeconds(forWindowHours: 6) == 87, "6 h -> 87 s")
        #expect(KernelLogCollector.timeoutSeconds(forWindowHours: 24) == 303, "24 h -> 303 s")
    }

    @Test("the collector hands the scaled timeout to the process layer")
    func theScaledTimeoutReachesTheExecutor() throws {
        let executor = RecordingExecutor([
            .logShow(last: "6h", predicate: ""): .ok(try collectorFixture("kernel-log-medium-errors.ndjson")),
        ])
        _ = KernelLogCollector(executor: executor).collect(bsd: "disk8", window: "6h")

        #expect(executor.requestedTimeouts == [87], "6 h asks for 87 s")
    }

    @Test("events attributed to another disk are dropped while the section stays ok")
    func anotherDisksEventsAreDropped() throws {
        let executor = RecordingExecutor([
            .logShow(last: "1h", predicate: ""): .ok(try collectorFixture("kernel-log-medium-errors.ndjson")),
        ])
        let collection = KernelLogCollector(executor: executor).collect(bsd: "disk4")

        #expect(collection.status == .ok, "the query itself succeeded")
        #expect(collection.events.isEmpty, "a measured empty event list, not an absent signal")
    }

    @Test("a kernel series with no disk-name line is still reported")
    func anUnattributedKernelSeriesIsKept() {
        // The sense line carries no disk name and a retry line carries only the
        // LBA, so dropping unattributed events would lose the real evidence.
        let text = """
        2026-11-07 00:34:39.222440+0800 Df kernel[0:0] [External] I/O error! Opcode 0x28, Service response 0x02, Task status 0x02, Sense Data 0x03, 0x11, 0x00
        2026-11-07 00:34:39.222455+0800 Df kernel[0:0] [External]: I/O error [0xe00002ca] dir 0x1 lba 0x800 count 0x100, retry 1 ...
        """
        let executor = RecordingExecutor([.logShow(last: "1h", predicate: ""): .ok(text)])
        let collection = KernelLogCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .ok, "status")
        #expect(collection.events.count == 1, "the unattributed series is kept")
        #expect(collection.events.first?.bsd == nil, "no line named a disk")
        #expect(collection.events.first?.lba == 2048, "the LBA is still evidence")
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
        #expect(failed.windowHours == nil, "a timed-out query measured no window")
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
