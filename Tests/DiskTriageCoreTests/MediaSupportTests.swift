import Foundation
import Testing
import DiskTriageCore

/// The one media-coverage rule shared by `classify` and `list`: NVMe/internal
/// SSD/flash/SD are not covered, and an unknown media type over USB is not
/// unsupported (diskdoctor.md §5 step [2], §12).
struct MediaSupportTests {

    private func device(media: String?, bus: String?) -> DeviceSignals {
        try! JSONDecoder.disktriage().decode(
            SignalSet.self,
            from: Data("""
            { "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
              "device": { "status": "ok", "bsd": "disk0", "media": \(media.map { "\"\($0)\"" } ?? "null"),
                          "bus": \(bus.map { "\"\($0)\"" } ?? "null") } }
            """.utf8)
        ).device!
    }

    @Test("NVMe, SSD, flash and SD are not covered")
    func unsupportedMediaIsNotCovered() {
        #expect(MediaSupport.unsupportedLabel(for: device(media: "ssd", bus: "sata")) == "ssd")
        #expect(MediaSupport.unsupportedLabel(for: device(media: "nvme", bus: "pcie")) == "nvme")
        #expect(MediaSupport.unsupportedLabel(for: device(media: "flash", bus: "usb")) == "flash")
        #expect(MediaSupport.unsupportedLabel(for: device(media: "sd", bus: "usb")) == "sd")
        #expect(MediaSupport.unsupportedLabel(for: device(media: "unknown", bus: "nvme")) == "NVMe")
    }

    @Test("an HDD and an unknown USB media type stay triageable")
    func hddAndUnknownUSBStayTriageable() {
        #expect(MediaSupport.unsupportedLabel(for: device(media: "hdd", bus: "usb")) == nil)
        #expect(MediaSupport.unsupportedLabel(for: device(media: "unknown", bus: "usb")) == nil,
                "P0 phase B: no SolidState key over USB means unknown, not unsupported")
        #expect(MediaSupport.unsupportedLabel(for: nil) == nil)
    }
}
