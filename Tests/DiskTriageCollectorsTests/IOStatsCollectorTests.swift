import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// The ioreg association, driven entirely from recorded output: the Statistics
/// query names the child IOMedia by node id, the IOMedia query names the disk.
struct IOStatsCollectorTests {

    @Test("the recorded internal pair associates the driver with disk0")
    func theRecordedInternalPairAssociatesToDisk0() throws {
        let executor = RecordingExecutor([
            .ioregStatistics: .ok(try collectorFixture("ioreg-internal-driver.txt")),
            .ioregMedia: .ok(try collectorFixture("ioreg-iomedia-internal.txt")),
        ])
        let collection = IOStatsCollector(executor: executor).collect(bsd: "disk0")

        #expect(collection.status == .ok, "association succeeded")
        let counters = try #require(collection.counters, "counters")
        #expect(counters.bytesRead == 300_776_579_072, "the recorded Bytes (Read)")
        #expect(counters.errorsRead == 0, "a measured zero is not nil")
        #expect(counters.retriesRead == 0, "a measured zero is not nil")
        #expect(executor.commands == [.ioregStatistics, .ioregMedia], "one snapshot, then the association query")
    }

    @Test("a disk with no IOMedia entry is unsupported, never guessed from a media name")
    func anUnassociatedDiskIsUnsupported() throws {
        let executor = RecordingExecutor([
            .ioregStatistics: .ok(try collectorFixture("ioreg-phase-c-after.txt")),
            .ioregMedia: .ok(try collectorFixture("ioreg-iomedia-internal.txt")),
        ])
        let collection = IOStatsCollector(executor: executor).collect(bsd: "disk8")

        #expect(collection.status == .unsupported, "the association is impossible")
        #expect(collection.counters == nil, "no counters are invented")
        let reason = try #require(collection.reason, "reason")
        #expect(reason.contains("disk8"), "the reason names the disk: \(reason)")
        #expect(reason.contains("IOMedia"), "the reason names the missing half")
    }

    // REQ-0012: a timeout is an unresponsive-device signal, not a crash and
    // not a zero-counter reading.
    @Test("a Statistics timeout is a timeout with no counters and no second query")
    func aStatisticsTimeoutIsATimeout() {
        let executor = RecordingExecutor([.ioregStatistics: .timeout()])
        let collection = IOStatsCollector(executor: executor).collect(bsd: "disk0")

        #expect(collection.status == .timeout, "status")
        #expect(collection.counters == nil, "counters are nil, not zero")
        #expect(collection.reason?.isEmpty == false, "reason")
        #expect(executor.commands == [.ioregStatistics], "the missing stats make the media query pointless")
    }

    @Test("a malformed Statistics body is an error, not an empty counter set")
    func malformedStatisticsIsAnError() {
        let executor = RecordingExecutor([.ioregStatistics: .ok("not ioreg")])
        let collection = IOStatsCollector(executor: executor).collect(bsd: "disk0")

        #expect(collection.status == .unsupported, "no driver block means no association")
        #expect(collection.counters == nil, "no counters")
    }
}
