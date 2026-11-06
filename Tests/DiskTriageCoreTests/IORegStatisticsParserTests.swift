import Foundation
import Testing
import DiskTriageCore

/// Pin the ioreg parser to the two real Phase B/C pairs. The expected deltas
/// are transcribed from docs/p0-runbook.md's Phase B and Phase C findings;
/// they are never recomputed from the same arithmetic the code performs.
struct IORegStatisticsParserTests {

    @Test("the real Phase B pair moves Bytes (Read) by exactly 64 MiB")
    func phaseBDeltaPinsTheControlDisk() throws {
        let before = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-b-before.txt"))
        let after = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-b-after.txt"))

        let seagate = try #require(
            IORegStatistics.delta(before: before, after: after)
                .first { $0.mediaName == "Seagate Expansion Media" },
            "the Seagate Expansion driver has a delta"
        )
        #expect(seagate.counters.bytesRead == 67_108_864, "Bytes (Read): 64 MiB")
        #expect(seagate.counters.operationsRead == 64, "Operations (Read): 64")
        #expect(seagate.counters.errorsRead == 0, "Errors (Read) on a healthy read")
        #expect(seagate.counters.retriesRead == 0, "Retries (Read) on a healthy read")
    }

    @Test("the real Phase C pair moves Bytes (Read) by 1 MiB and Errors (Read) 0 -> 1")
    func phaseCDeltaPinsTheFailingDisk() throws {
        let before = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-c-before.txt"))
        let after = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-c-after.txt"))

        let minah = try #require(
            IORegStatistics.delta(before: before, after: after)
                .first { $0.mediaName == "Generic External Media" },
            "the MiNaH driver has a delta"
        )
        #expect(minah.counters.bytesRead == 1_048_576, "Bytes (Read): the one good MiB")
        #expect(minah.counters.errorsRead == 1, "Errors (Read): 0 -> 1")
        #expect(minah.counters.retriesRead == 0, "Retries stayed 0 despite 20 kernel retries")
    }

    @Test("the Statistics block does not name its BSD disk, so no association is invented")
    func theStatisticsOutputCannotNameItsBSDDevice() throws {
        let stats = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-c-before.txt"))

        let driver = try #require(stats.drivers.first, "one driver block")
        #expect(driver.nodeID == "0x100004d8c", "the IORegistry node id")
        #expect(driver.mediaName == "Generic External Media", "the child IOMedia name")
        #expect(driver.bsdName == nil, "-k Statistics carries no BSD Name")
        #expect(stats.driver(forBSD: "disk8") == nil,
                "without the IOMedia query the association is unknown, never guessed")
    }

    @Test("empty output is no drivers, not a zero counter set")
    func emptyOutputIsNoDrivers() throws {
        let stats = try IORegStatisticsParser.parse("")
        #expect(stats.drivers.isEmpty, "no driver blocks parsed")
    }
}

private func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixtureData(name), as: UTF8.self)
}
