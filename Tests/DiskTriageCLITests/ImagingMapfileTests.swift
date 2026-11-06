import Foundation
import Testing
@testable import DiskTriageCLI

/// The GNU ddrescue mapfile parser. The samples below are real output from
/// ddrescue 1.30 on a regular file (no device is touched), plus one hand-written
/// sample in the same format for the statuses a healthy file never produces.
struct ImagingMapfileTests {

    // Generated with:
    //   head -c 2097152 /dev/urandom > src.bin
    //   ddrescue -n -s 1048576 src.bin out.img out.map
    // It stopped after 1 MiB and left the second MiB non-tried.
    private static let realPartialMapfile = """
    # Mapfile. Created by GNU ddrescue version 1.30
    # Command line: /opt/homebrew/bin/ddrescue -n -s 1048576 src.bin out.img out.map
    # Start time:   2026-11-07 01:57:06
    # Current time: 2026-11-07 01:57:06
    # Finished
    # current_pos  current_status  current_pass
    0x000F0000     +               1
    #      pos        size  status
    0x00000000  0x00100000  +
    0x00100000  0x00100000  ?

    """

    // Every status character, in the real column layout. The `current_pos`
    // row must not be counted as an extent.
    private static let mixedMapfile = """
    # Mapfile. Created by GNU ddrescue version 1.30
    # Command line: ddrescue -r3 in out map
    # Start time:   2026-11-07 01:00:00
    # Current time: 2026-11-07 01:10:00
    # current_pos  current_status  current_pass
    0x00001000     /               2
    #      pos        size  status
    0x00000000  0x00001000  +
    0x00001000  0x00000200  -
    0x00001200  0x00000100  *
    0x00001300  0x00000100  /
    0x00001400  0x00001000  ?

    """

    @Test("REQ0076 a real partial mapfile parses to rescued and non-tried bytes")
    func REQ0076_parsesARealDdrescueMapfile() throws {
        let snapshot = try #require(DdrescueMapfile.parse(Self.realPartialMapfile))

        #expect(snapshot.rescuedBytes == 1_048_576)
        #expect(snapshot.nonTriedBytes == 1_048_576)
        #expect(snapshot.badBytes == 0)
        #expect(snapshot.remainingBytes == 1_048_576)
        #expect(snapshot.remainingExtents.count == 1)
        #expect(snapshot.remainingExtents.first?.position == 1_048_576)
        #expect(snapshot.remainingExtents.first?.size == 1_048_576)
        #expect(snapshot.pass == 1)
        #expect(snapshot.finished)
    }

    @Test("every ddrescue status character is counted once and the current_pos row is skipped")
    func countsEachStatusCharacter() throws {
        let snapshot = try #require(DdrescueMapfile.parse(Self.mixedMapfile))

        #expect(snapshot.rescuedBytes == 4096)
        #expect(snapshot.badBytes == 512)
        #expect(snapshot.nonTrimmedBytes == 256)
        #expect(snapshot.nonScrapedBytes == 256)
        #expect(snapshot.nonTriedBytes == 4096)
        #expect(snapshot.remainingBytes == 512 + 256 + 256 + 4096)
        #expect(snapshot.remainingExtents.count == 4)
        #expect(snapshot.pass == 2)
        #expect(!snapshot.finished)
    }

    @Test("an empty or not-yet-written mapfile is not a measurement")
    func emptyMapfileIsNil() {
        #expect(DdrescueMapfile.parse("") == nil)
        #expect(DdrescueMapfile.parse("not a mapfile\n") == nil)
    }

    @Test("a finished mapfile with only rescued extents is complete")
    func finishedMapfileIsComplete() throws {
        let text = """
        # Mapfile. Created by GNU ddrescue version 1.30
        # Finished
        # current_pos  current_status  current_pass
        0x00001000     +               1
        #      pos        size  status
        0x00000000  0x00001000  +

        """
        let snapshot = try #require(DdrescueMapfile.parse(text))
        #expect(snapshot.rescuedBytes == 4096)
        #expect(snapshot.remainingBytes == 0)
        #expect(snapshot.isComplete)
    }

    // MARK: - A partial image's unbounded tail (diskdoctor.md §8 `--limit`)

    private static let partialLimit: Int64 = 3_221_225_472 // 3 GiB
    private static let rescuedBeforeTheLimit: Int64 = 2_405_761_024 // 0x8F650000

    private static func fixture(_ name: String) -> String {
        (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
    }

    // REQ-0108: `ddrescue -s` leaves the untried tail ending at Int64.max.
    // Without a limit the mapfile is read exactly as before; with the partial
    // limit every extent is clipped to [0, limit).
    @Test("REQ0108 a partial mapfile's unbounded untried tail is clipped to the limit")
    func REQ0108_partialMapfileClipsTheUnboundedTail() throws {
        let text = Self.fixture("partial-limit-huge-tail.mapfile.txt")

        let unclamped = try #require(DdrescueMapfile.parse(text))
        #expect(unclamped.rescuedBytes == Self.rescuedBeforeTheLimit)
        #expect(unclamped.remainingBytes == Int64.max - Self.rescuedBeforeTheLimit,
                "a full image keeps today's accounting, including the tail")
        #expect(unclamped.remainingExtents.count == 1)

        let snapshot = try #require(DdrescueMapfile.parse(text, limitBytes: Self.partialLimit))
        #expect(snapshot.rescuedBytes == Self.rescuedBeforeTheLimit)
        #expect(snapshot.badBytes == 0)
        #expect(snapshot.remainingBytes == 815_464_448, "3 GiB minus the rescued bytes")
        #expect(snapshot.remainingExtents.count == 1)
        #expect(snapshot.remainingExtents.first?.position == Self.rescuedBeforeTheLimit)
        #expect(snapshot.remainingExtents.first?.size == 815_464_448,
                "the untried tail is clipped at the limit, not Int64.max")
        #expect(!snapshot.isComplete)
        #expect(abs(snapshot.rescuedFraction - 0.7468) < 0.0001,
                "the percentage is of the limit, not of 8.6 billion GiB")
    }

    // REQ-0108: a partial mapfile that rescued the whole limit is complete,
    // even though the tail extent starts at the limit and runs to Int64.max.
    @Test("REQ0108 a partial mapfile rescued to the limit is complete despite the tail")
    func REQ0108_fullyRescuedToTheLimitIsComplete() throws {
        let text = Self.fixture("partial-limit-fully-rescued.mapfile.txt")
        let snapshot = try #require(DdrescueMapfile.parse(text, limitBytes: Self.partialLimit))

        #expect(snapshot.rescuedBytes == Self.partialLimit)
        #expect(snapshot.badBytes == 0)
        #expect(snapshot.remainingBytes == 0)
        #expect(snapshot.remainingExtents.isEmpty)
        #expect(snapshot.extents.count == 1, "the extent starting at the limit is dropped")
        #expect(snapshot.isComplete)
        #expect(snapshot.rescuedFraction == 1.0)
    }

    // REQ-0108: a bad extent that crosses the limit contributes only the bytes
    // inside the range, and bad bytes are not "remaining to try" inside it.
    @Test("REQ0108 a bad extent straddling the limit is clipped at the limit")
    func REQ0108_badExtentStraddlingTheLimitIsClipped() throws {
        let text = Self.fixture("partial-limit-bad-straddles.mapfile.txt")
        let snapshot = try #require(DdrescueMapfile.parse(text, limitBytes: Self.partialLimit))

        #expect(snapshot.rescuedBytes == 1_073_741_824, "1 GiB rescued")
        #expect(snapshot.badBytes == 2_147_483_648,
                "the 4 GiB bad extent is clipped to the 2 GiB inside the 3 GiB limit")
        #expect(snapshot.remainingBytes == 0, "limit - rescued - bad")
        #expect(snapshot.remainingExtents.isEmpty)
        #expect(snapshot.isComplete)
        #expect(snapshot.extents.contains { $0.status == "-" && $0.size == 2_147_483_648 },
                "the written extents are clipped too")
        #expect(abs(snapshot.rescuedFraction - 1.0 / 3.0) < 0.0001)
    }
}
