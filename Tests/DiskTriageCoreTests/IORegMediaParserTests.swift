import Foundation
import Testing
import DiskTriageCore

/// The association query the P1d parser could not answer alone: `ioreg -r -c
/// IOMedia -d 1 -w 0` names the whole-disk IOMedia node, and the Statistics
/// block names its child IOMedia by node id. Nothing here guesses a mapping
/// from a name alone.
struct IORegMediaParserTests {

    @Test("the recorded internal IOMedia output names the whole disk and its node id")
    func theRecordedIOMediaOutputNamesTheWholeDisk() throws {
        let media = try IORegMediaParser.parse(fixtureText("ioreg-iomedia-internal.txt"))

        let disk0 = try #require(media.first, "one whole-disk entry")
        #expect(disk0.nodeID == "0x1000006f0", "the IOMedia node id the Statistics child carries")
        #expect(disk0.name == "APPLE SSD AP0256Q Media", "the media name")
        #expect(disk0.bsdName == "disk0", "BSD Name => disk0")
        #expect(disk0.whole == true, "Whole = Yes")
    }

    @Test("the Statistics child node id links the driver to the IOMedia BSD name")
    func theTwoOutputsAssociateDriverAndBSDName() throws {
        let stats = try IORegStatisticsParser.parse(fixtureText("ioreg-internal-driver.txt"))
        let media = try IORegMediaParser.parse(fixtureText("ioreg-iomedia-internal.txt"))

        let internalDriver = try #require(
            stats.driver(forBSD: "disk0", media: media),
            "the internal disk driver"
        )
        #expect(internalDriver.nodeID == "0x1000006ee", "driver node")
        #expect(internalDriver.mediaName == "APPLE SSD AP0256Q Media", "child media")
        #expect(internalDriver.counters.errorsRead == 0, "Errors (Read) on the internal driver")
        #expect(internalDriver.counters.bytesRead == 300_776_579_072,
                "Bytes (Read) from the Phase C after capture")
    }

    @Test("the Phase B and C driver excerpts have no IOMedia match, so the association is absent")
    func unassociatedDriversAreUnknown() throws {
        let media = try IORegMediaParser.parse(fixtureText("ioreg-iomedia-internal.txt"))
        let phaseB = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-b-after.txt"))
        let phaseC = try IORegStatisticsParser.parse(fixtureText("ioreg-phase-c-after.txt"))

        // The external disks' `BSD Name` recordings were never committed, so
        // the requirement is an absent association, not an invented disk8.
        #expect(phaseB.driver(forBSD: "disk8", media: media) == nil, "Seagate has no IOMedia entry")
        #expect(phaseC.driver(forBSD: "disk8", media: media) == nil, "MiNaH has no IOMedia entry")
    }

    @Test("empty IOMedia output is no entries")
    func emptyOutputIsNoEntries() throws {
        #expect(try IORegMediaParser.parse("").isEmpty, "no blocks")
    }
}

private func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixtureData(name), as: UTF8.self)
}
