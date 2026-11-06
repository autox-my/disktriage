import Foundation

/// The one media-coverage rule (diskdoctor.md §5 step [2], §12).
///
/// NVMe, internal SSD, USB flash and SD cards are outside v1 classification.
/// An absent `SolidState` key over USB means media type `unknown`, which is
/// *not* unsupported: P0 phase B measured that case on both bridges.
///
/// The classifier and `list` both ask this, so a device can never be
/// "triage not applicable" in `list` while the classifier still classifies it.
public enum MediaSupport {
    private static let unsupportedMedia = ["ssd", "nvme", "flash", "sd", "sdcard"]

    /// The label to show for unsupported media, or nil when triage applies.
    public static func unsupportedLabel(for device: DeviceSignals?) -> String? {
        unsupportedLabel(media: device?.media, bus: device?.bus)
    }

    /// The same rule for collectors that hold a `DeviceIdentity` rather than a
    /// `DeviceSignals` (the `list` command).
    public static func unsupportedLabel(media: String?, bus: String?) -> String? {
        if let media = media?.lowercased(), unsupportedMedia.contains(media) {
            return media
        }
        if let bus = bus?.lowercased(), bus == "nvme" {
            return "NVMe"
        }
        return nil
    }
}
