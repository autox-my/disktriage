import Foundation
import Testing
import DiskTriageCore

/// The identity path that does not need `diskutil`, so it keeps working while
/// diskarbitrationd is suspended (P0 phase C: `diskutil` hangs system-wide).
/// The expectations below are read off the recorded fixtures, never recomputed
/// the way the parser computes them.
struct IORegDeviceParserTests {

    /// Table-driven over the three real shapes: an internal NVMe, a USB HDD
    /// whose bridge exposes no serial, and a USB SSD whose serial is only on
    /// the USB host device.
    @Test("REQ-0162 the recorded IOBlockStorageDevice trees parse to the identity table")
    func REQ0162_recordedDeviceTreesParseToTheIdentityTable() throws {
        struct Row {
            let fixture: String
            let bsd: String
            let size: Int64
            let block: Int64
            let model: String
            let vendor: String?
            let serial: String?
            let bus: String
            let media: String?
            let removable: Bool
            let ejectable: Bool
            let internalDisk: Bool
        }

        let rows: [Row] = [
            Row(
                fixture: "ioreg-device-internal.txt",
                bsd: "disk0",
                size: 251_000_193_024,
                block: 4096,
                model: "APPLE SSD AP0256Q",
                vendor: nil,
                serial: "REDACTED0000ABCD",
                bus: "nvme",
                media: "ssd",
                removable: false,
                ejectable: false,
                internalDisk: true
            ),
            Row(
                fixture: "ioreg-device-usb-hdd-no-serial.txt",
                bsd: "disk8",
                size: 5_000_981_077_504,
                block: 512,
                model: "Expansion",
                vendor: "Seagate",
                serial: nil,
                bus: "usb",
                media: nil,
                removable: false,
                ejectable: true,
                internalDisk: false
            ),
            Row(
                fixture: "ioreg-device-usb-with-serial.txt",
                bsd: "disk8",
                size: 250_059_350_016,
                block: 512,
                model: "SSD 850 EVO",
                vendor: "Samsung",
                serial: "DEMO-USB-0000ABCD",
                bus: "usb",
                media: "ssd",
                removable: false,
                ejectable: true,
                internalDisk: false
            ),
        ]

        for row in rows {
            let text = String(decoding: try fixtureData(row.fixture), as: UTF8.self)
            let identity = try #require(
                IORegDeviceParser.parse(text, bsd: row.bsd),
                "\(row.fixture) has a whole disk \(row.bsd)"
            )
            #expect(identity.bsd == row.bsd, "\(row.fixture): bsd")
            #expect(identity.sizeBytes == row.size, "\(row.fixture): size")
            #expect(identity.blockSize == row.block, "\(row.fixture): block size")
            #expect(identity.model == row.model, "\(row.fixture): model")
            #expect(identity.vendor == row.vendor, "\(row.fixture): vendor")
            // REQ-0163: an unexposed serial stays nil; it is never invented.
            #expect(identity.serial == row.serial, "\(row.fixture): serial")
            #expect(identity.bus == row.bus, "\(row.fixture): bus")
            #expect(identity.media == row.media, "\(row.fixture): media")
            #expect(identity.removable == row.removable, "\(row.fixture): removable")
            #expect(identity.ejectable == row.ejectable, "\(row.fixture): ejectable")
            #expect(identity.internalDisk == row.internalDisk, "\(row.fixture): internal")
            #expect(identity.whole == true, "\(row.fixture): whole disk")
        }
    }

    @Test("a tree with no matching whole-disk IOMedia is no identity")
    func aMissingWholeDiskIsNoIdentity() throws {
        let text = String(decoding: try fixtureData("ioreg-device-internal.txt"), as: UTF8.self)
        #expect(IORegDeviceParser.parse(text, bsd: "disk8") == nil, "disk8 is not in this tree")
        #expect(IORegDeviceParser.parse("", bsd: "disk0") == nil, "empty output is no identity")
    }

    @Test("a slice with the same BSD unit is not the whole disk")
    func aSliceIsNotTheWholeDisk() throws {
        let text = """
        +-o IOBlockStorageDevice  <class IOBlockStorageDevice, id 0x1>
          | {
          |   "Device Characteristics" = {"Product Name"="Expansion","Vendor Name"="Seagate"}
          |   "Protocol Characteristics" = {"Physical Interconnect"="USB","Physical Interconnect Location"="External"}
          | }
          +-o Expansion Media  <class IOMedia, id 0x2>
            | {
            |   "Whole" = No
            |   "BSD Name" = "disk8"
            |   "Size" = 5000981077504
            |   "Preferred Block Size" = 512
            | }
        """
        #expect(IORegDeviceParser.parse(text, bsd: "disk8") == nil, "Whole = No is not the disk")
    }
}
