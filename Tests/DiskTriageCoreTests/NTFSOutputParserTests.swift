import Foundation
import Testing
import DiskTriageCore

/// Parsers for the two ntfs-3g outputs `inspect` reads. The fixtures are real
/// output recorded in `captures/ntfs-spike/` (device names redacted); the
/// expectations are the values the spike recorded, not recomputed here.
struct NTFSOutputParserTests {

    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DiskTriageCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("ntfsinfo -m parses to the volume geometry the spike recorded")
    func parsesTheVolumeInfo() throws {
        let text = try Self.fixture("ntfsinfo-plain.txt")
        let info = try #require(NTFSVolumeInfoParser.parse(text))

        #expect(info.volumeName == "NTFS64")
        #expect(info.volumeVersion == "3.1")
        #expect(info.volumeFlags == "0x0000")
        #expect(info.sectorSize == 512)
        #expect(info.clusterSize == 4096)
        #expect(info.indexBlockSize == 4096)
        #expect(info.volumeSizeClusters == 16_383)
        #expect(info.freeClusters == 4_075)
    }

    @Test("an unrelated text is not volume info")
    func rejectsUnrelatedText() {
        #expect(NTFSVolumeInfoParser.parse("") == nil)
        #expect(NTFSVolumeInfoParser.parse("hello world\n") == nil)
    }

    @Test("ntfsls -l parses the root names, sizes and optional inode numbers")
    func parsesTheRootListing() throws {
        let root = try Self.fixture("ntfsls-root.txt")
        let listing = NTFSListingParser.parse(root)
        #expect(!listing.truncated)
        #expect(listing.entries.map(\.name) == ["deep", "docs", "empty-dir", "media"])
        #expect(listing.entries.allSatisfy { $0.sizeBytes == 0 })

        // `-l -R -i` (the spike's listing) puts an inode column in front.
        let withInodes = """
        /:
             67           0 Nov  6 23:02 2026 deep
             64        2048 Nov  6 23:02 2026 readme.txt

        """
        let inodes = NTFSListingParser.parse(withInodes)
        #expect(inodes.entries.count == 2)
        #expect(inodes.entries[0].inode == 67)
        #expect(inodes.entries[0].sizeBytes == 0)
        #expect(inodes.entries[1].inode == 64)
        #expect(inodes.entries[1].sizeBytes == 2048)
    }

    @Test("ntfsls -R parses directory headers and names, dropping . and ..")
    func parsesTheRecursiveListing() throws {
        let text = try Self.fixture("ntfsls-recursive.txt")
        let listing = NTFSListingParser.parse(text)

        #expect(!listing.truncated)
        #expect(listing.directoryCount == 9)
        #expect(listing.entries.contains { $0.name == "readme.txt" && $0.directory == "/docs" })
        #expect(listing.entries.contains { $0.name == "leaf.dat" && $0.directory == "/deep/a/b/c" })
        #expect(!listing.entries.contains { $0.name == "." || $0.name == ".." })
        #expect(listing.entries.count == 44, "the fixture's real content lines minus . and ..")
    }

    @Test("the listing cap stops parsing and reports truncation")
    func capsTheListing() throws {
        let text = try Self.fixture("ntfsls-root.txt")
        let listing = NTFSListingParser.parse(text, maxEntries: 2)
        #expect(listing.entries.count == 2)
        #expect(listing.truncated)
    }
}
