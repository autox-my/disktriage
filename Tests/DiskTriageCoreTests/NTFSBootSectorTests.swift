import Foundation
import Testing
import DiskTriageCore

/// The boot-sector rules from diskdoctor.md §8: the OEM ID, the geometry
/// fields and `55 AA`, plus the backup-sector offset that P0 row 11 fixed.
struct NTFSBootSectorTests {

    @Test("a valid NTFS boot sector yields the geometry the tools use")
    func parsesTheGeometry() throws {
        let sector = Self.bootSector(bytesPerSector: 512, sectorsPerCluster: 8, totalSectors: 131_071)
        let validation = NTFSBootSectorRules.validate(Data(sector))
        let boot = try #require(validation.bootSector)

        #expect(boot.oemID == "NTFS    ")
        #expect(boot.bytesPerSector == 512)
        #expect(boot.sectorsPerCluster == 8)
        #expect(boot.clusterSize == 4096)
        #expect(boot.totalSectors == 131_071)
    }

    @Test("every invalid boot-sector field is rejected with a reason")
    func rejectsInvalidFields() {
        var wrongOEM = Self.bootSector()
        wrongOEM[3] = Character("X").asciiValue!
        #expect(NTFSBootSectorRules.validate(Data(wrongOEM)).bootSector == nil)
        #expect(NTFSBootSectorRules.validate(Data(wrongOEM)).reason?.contains("OEM") == true)

        var wrongSector = Self.bootSector()
        wrongSector[0x0B] = 0x00
        wrongSector[0x0C] = 0x03 // 768, not in {512, 1024, 2048, 4096}
        #expect(NTFSBootSectorRules.validate(Data(wrongSector)).bootSector == nil)

        var wrongCluster = Self.bootSector()
        wrongCluster[0x0D] = 3 // not a power of two
        #expect(NTFSBootSectorRules.validate(Data(wrongCluster)).bootSector == nil)

        var noSignature = Self.bootSector()
        noSignature[510] = 0x00
        #expect(NTFSBootSectorRules.validate(Data(noSignature)).bootSector == nil)
        #expect(NTFSBootSectorRules.validate(Data(noSignature)).reason?.contains("55 AA") == true)
    }

    // REQ-0119: the backup is the last sector of the *partition*, taken from
    // the partition table, not the disk's last sector and not the BPB.
    @Test("REQ0119 the backup boot sector is the last sector of the partition")
    func REQ0119_backupOffsetIsTheLastSectorOfThePartition() {
        // The spike's disk.img: 64 MiB partition at byte 1048576.
        #expect(NTFSBootSectorRules.backupOffset(
            partitionOffset: 1_048_576,
            partitionLengthBytes: 67_108_864
        ) == 68_156_928)

        // The spike's bare plain.img: offset 0, file size 67108864.
        #expect(NTFSBootSectorRules.backupOffset(
            partitionOffset: 0,
            partitionLengthBytes: 67_108_864
        ) == 67_108_352)

        #expect(NTFSBootSectorRules.backupOffset(
            partitionOffset: 0,
            partitionLengthBytes: 511
        ) == nil)
    }

    // MARK: - Filesystem detection (REQ-0120)

    @Test("REQ0120 the cheap volume magics are recognised")
    func REQ0120_detectsTheVolumeMagics() {
        #expect(FileSystemDetector.detect(Data(Self.bootSector())) == .ntfs)
        #expect(FileSystemDetector.detect(Self.apfsPrefix()) == .apfs)
        #expect(FileSystemDetector.detect(Self.exfatPrefix()) == .exfat)
        #expect(FileSystemDetector.detect(Self.fat32Prefix()) == .fat)
        #expect(FileSystemDetector.detect(Self.hfsPlusPrefix()) == .hfsPlus)
        #expect(FileSystemDetector.detect(Data(repeating: 0xAB, count: 2048)) == .unknown)
    }

    // MARK: - Hand-built bytes

    static func bootSector(
        bytesPerSector: UInt16 = 512,
        sectorsPerCluster: UInt8 = 8,
        totalSectors: UInt64 = 131_071
    ) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: 512)
        sector.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        sector.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        sector[0x0B] = UInt8(bytesPerSector & 0xFF)
        sector[0x0C] = UInt8(bytesPerSector >> 8)
        sector[0x0D] = sectorsPerCluster
        for i in 0..<8 {
            sector[0x28 + i] = UInt8((totalSectors >> (8 * UInt64(i))) & 0xFF)
        }
        sector[510] = 0x55
        sector[511] = 0xAA
        return sector
    }

    private static func apfsPrefix() -> Data {
        var bytes = [UInt8](repeating: 0, count: 2048)
        bytes.replaceSubrange(32..<36, with: Array("NXSB".utf8))
        return Data(bytes)
    }

    private static func exfatPrefix() -> Data {
        var bytes = [UInt8](repeating: 0, count: 2048)
        bytes.replaceSubrange(3..<11, with: Array("EXFAT   ".utf8))
        return Data(bytes)
    }

    private static func fat32Prefix() -> Data {
        var bytes = [UInt8](repeating: 0, count: 2048)
        bytes.replaceSubrange(82..<90, with: Array("FAT32   ".utf8))
        return Data(bytes)
    }

    private static func hfsPlusPrefix() -> Data {
        var bytes = [UInt8](repeating: 0, count: 2048)
        bytes.replaceSubrange(1024..<1026, with: [0x48, 0x2B]) // "H+"
        return Data(bytes)
    }
}

private extension NTFSBootSectorValidation {
    /// Test convenience: the parsed value or nil.
    var bootSector: NTFSBootSector? {
        if case .valid(let boot) = self { return boot }
        return nil
    }

    var reason: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}
