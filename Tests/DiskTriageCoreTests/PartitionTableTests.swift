import Foundation
import Testing
import DiskTriageCore

/// The partition-table parser is pure: the tests build sector bytes by hand,
/// so no image, no disk and no filesystem is involved.
struct PartitionTableTests {

    // REQ-0115: a whole-disk image's NTFS partition comes from the table.
    @Test("REQ0115 an MBR with one type-0x07 partition names its offset and length")
    func REQ0115_parsesAnMBRWithOneNTFSPartition() throws {
        var sector = [UInt8](repeating: 0, count: 512)
        mbrEntry(&sector, index: 0, type: 0x07, startLBA: 2048, sectors: 131_072)
        sector[510] = 0x55
        sector[511] = 0xAA

        let table = try #require(PartitionTableParser.parseMBR(Data(sector)))
        #expect(table.scheme == .mbr)
        #expect(table.sectorSize == 512)
        #expect(table.partitions.count == 1)

        let partition = try #require(table.partitions.first)
        #expect(partition.index == 1)
        #expect(partition.startLBA == 2048)
        #expect(partition.byteOffset == 1_048_576)
        #expect(partition.byteLength == 67_108_864)
        #expect(table.ntfsCandidates == [partition])
    }

    @Test("a sector without the 55 AA signature is not a partition table")
    func rejectsASectorWithoutTheSignature() {
        #expect(PartitionTableParser.parseMBR(Data(repeating: 0, count: 512)) == nil)
        #expect(PartitionTableParser.parseMBR(Data(repeating: 0, count: 100)) == nil)
    }

    @Test("an MBR signature with no entries is an empty table, not an NTFS partition")
    func emptyMBRIsAnEmptyTable() throws {
        var sector = [UInt8](repeating: 0, count: 512)
        sector[510] = 0x55
        sector[511] = 0xAA

        let table = try #require(PartitionTableParser.parseMBR(Data(sector)))
        #expect(table.partitions.isEmpty)
        #expect(table.ntfsCandidates.isEmpty)
    }

    @Test("the protective 0xEE entry is never an NTFS candidate")
    func protectiveEntryIsNotNTFS() throws {
        var sector = [UInt8](repeating: 0, count: 512)
        mbrEntry(&sector, index: 0, type: 0xEE, startLBA: 1, sectors: 0xFFFF_FFFF)
        sector[510] = 0x55
        sector[511] = 0xAA

        let table = try #require(PartitionTableParser.parseMBR(Data(sector)))
        #expect(table.isProtective)
        #expect(table.ntfsCandidates.isEmpty)
    }

    // REQ-0115: GPT basic data is the NTFS candidate; the EFI system partition
    // before it is not.
    @Test("REQ0115 a GPT entry array names the Microsoft basic-data partition")
    func REQ0115_parsesAGPTAndFindsTheBasicDataPartition() throws {
        let header = gptHeader(entriesLBA: 2, entryCount: 128, entrySize: 128)
        var entries = [UInt8](repeating: 0, count: 128 * 128)
        gptEntry(&entries, index: 0, type: Self.efiSystemGUID, startLBA: 2048, sectors: 204_800)
        gptEntry(&entries, index: 1, type: Self.microsoftBasicDataGUID, startLBA: 206_848, sectors: 131_072)

        let locator = try #require(PartitionTableParser.parseGPTHeader(Data(header)))
        let table = try #require(PartitionTableParser.parseGPTEntries(locator, entries: Data(entries)))

        #expect(table.scheme == .gpt)
        #expect(table.partitions.count == 2)
        #expect(table.ntfsCandidates.count == 1)
        let partition = try #require(table.ntfsCandidates.first)
        #expect(partition.index == 2)
        #expect(partition.startLBA == 206_848)
        #expect(partition.byteOffset == 206_848 * 512)
    }

    @Test("a GPT header with a bad signature or a truncated entry array is rejected")
    func rejectsMalformedGPT() throws {
        var header = gptHeader(entriesLBA: 2, entryCount: 128, entrySize: 128)
        header[0] = 0x00
        #expect(PartitionTableParser.parseGPTHeader(Data(header)) == nil)

        let locator = try #require(
            PartitionTableParser.parseGPTHeader(Data(gptHeader(entriesLBA: 2, entryCount: 4, entrySize: 128)))
        )
        #expect(PartitionTableParser.parseGPTEntries(locator, entries: Data(repeating: 0, count: 256)) == nil)
    }

    // MARK: - Hand-built bytes

    private static let microsoftBasicDataGUID: [UInt8] = [
        0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
        0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7,
    ]

    private static let efiSystemGUID: [UInt8] = [
        0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
        0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
    ]

    private func mbrEntry(
        _ sector: inout [UInt8],
        index: Int,
        type: UInt8,
        startLBA: UInt32,
        sectors: UInt32
    ) {
        let base = 446 + index * 16
        sector[base] = 0x00
        sector[base + 4] = type
        putLE32(&sector, at: base + 8, value: startLBA)
        putLE32(&sector, at: base + 12, value: sectors)
    }

    private func gptHeader(entriesLBA: UInt64, entryCount: UInt32, entrySize: UInt32) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        let signature = Array("EFI PART".utf8)
        header.replaceSubrange(0..<8, with: signature)
        putLE32(&header, at: 8, value: 0x0001_0000)   // revision 1.0
        putLE32(&header, at: 12, value: 92)           // header size
        putLE64(&header, at: 24, value: 1)            // current LBA
        putLE64(&header, at: 72, value: entriesLBA)
        putLE32(&header, at: 80, value: entryCount)
        putLE32(&header, at: 84, value: entrySize)
        return header
    }

    private func gptEntry(
        _ entries: inout [UInt8],
        index: Int,
        type: [UInt8],
        startLBA: UInt64,
        sectors: UInt64
    ) {
        let base = index * 128
        entries.replaceSubrange(base..<(base + 16), with: type)
        putLE64(&entries, at: base + 32, value: startLBA)
        putLE64(&entries, at: base + 40, value: startLBA + sectors - 1)
    }

    private func putLE32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }

    private func putLE64(_ bytes: inout [UInt8], at offset: Int, value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }
}
