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
}
