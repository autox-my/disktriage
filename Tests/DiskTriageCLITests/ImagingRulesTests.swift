import Foundation
import Testing
@testable import DiskTriageCLI

/// The pure rules behind `disktriage image` (diskdoctor.md §6, §8).
/// Every expectation here is hand-computed from the plan, not from the
/// implementation.
struct ImagingRulesTests {

    // REQ-0079: the destination is not on the source disk.
    @Test("REQ0079 a destination on the source disk is refused")
    func REQ0079_destinationOnSourceDiskIsDetected() {
        #expect(destinationSharesSourceDisk(backingWholeDisk: "disk0", sourceDisk: "disk0") == true)
        #expect(destinationSharesSourceDisk(backingWholeDisk: "disk8", sourceDisk: "disk0") == false)
        #expect(destinationSharesSourceDisk(backingWholeDisk: nil, sourceDisk: "disk0") == nil,
                "an unresolved backing disk is not a pass")
        #expect(destinationSharesSourceDisk(backingWholeDisk: "disk8", sourceDisk: nil) == nil,
                "an unresolved source disk is not a pass")
    }

    // REQ-0079: enough free space for the full device.
    @Test("REQ0079 free space must cover the whole device, boundary included")
    func REQ0079_freeSpaceCoversTheWholeDevice() {
        #expect(freeSpaceCoversDevice(freeBytes: 1_000, deviceBytes: 1_000) == true,
                "exactly enough is enough")
        #expect(freeSpaceCoversDevice(freeBytes: 999, deviceBytes: 1_000) == false)
        #expect(freeSpaceCoversDevice(freeBytes: 1_001, deviceBytes: 1_000) == true)
        #expect(freeSpaceCoversDevice(freeBytes: nil, deviceBytes: 1_000) == nil)
        #expect(freeSpaceCoversDevice(freeBytes: 1_000, deviceBytes: nil) == nil)
    }

    // REQ-0079: a filesystem without the 4 GiB file-size limit.
    @Test("REQ0079 FAT32/MS-DOS is refused; APFS, HFS+ and exFAT are not")
    func REQ0079_fat32IsRefused() {
        #expect(filesystemAllowsLargeFiles("msdos") == false, "MS-DOS/FAT32 stops at 4 GiB")
        #expect(filesystemAllowsLargeFiles("fat32") == false)
        #expect(filesystemAllowsLargeFiles("apfs") == true)
        #expect(filesystemAllowsLargeFiles("hfs") == true)
        #expect(filesystemAllowsLargeFiles("exfat") == true)
        #expect(filesystemAllowsLargeFiles(nil) == nil, "an unknown filesystem is not a pass")
    }

    // REQ-0079: the destination must be writable.
    @Test("REQ0079 an unwritable destination is refused")
    func REQ0079_writableIsRequired() {
        #expect(destinationIsWritable(true) == true)
        #expect(destinationIsWritable(false) == false)
        #expect(destinationIsWritable(nil) == nil)
    }

    // REQ-0078: never overwrite an existing image with no matching mapfile.
    @Test("REQ0078 an existing image without a mapfile is refused")
    func REQ0078_existingImageWithoutMapfileIsRefused() {
        #expect(existingImageNeedsMapfile(imageExists: true, mapfileExists: false) == true)
        #expect(existingImageNeedsMapfile(imageExists: true, mapfileExists: true) == false)
        #expect(existingImageNeedsMapfile(imageExists: false, mapfileExists: false) == false)
        #expect(existingImageNeedsMapfile(imageExists: false, mapfileExists: true) == false)
    }

    // REQ-0077: a resume is valid only when the sidecar names this device.
    @Test("REQ0077 the sidecar must match size, serial hash and model")
    func REQ0077_sidecarMustMatchTheDevice() {
        let sidecar = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(model: "Expansion", serialSHA256: "abc123", sizeBytes: 100)
        )

        #expect(sidecarMatchesDevice(sidecar, model: "Expansion", serialHash: "abc123", sizeBytes: 100) == true)
        #expect(sidecarMatchesDevice(sidecar, model: "Expansion", serialHash: "deadbeef", sizeBytes: 100) == false,
                "a different serial is a different device")
        #expect(sidecarMatchesDevice(sidecar, model: "Other", serialHash: "abc123", sizeBytes: 100) == false)
        #expect(sidecarMatchesDevice(sidecar, model: "Expansion", serialHash: "abc123", sizeBytes: 101) == false)
        #expect(sidecarMatchesDevice(sidecar, model: "Expansion", serialHash: nil, sizeBytes: 100) == false,
                "the sidecar records a serial the current read cannot confirm")
        #expect(sidecarMatchesDevice(nil, model: "Expansion", serialHash: "abc123", sizeBytes: 100) == nil,
                "no sidecar is not a pass")
    }

    // REQ-0083: pass 1 is -n, pass 2 is -r3, both on /dev/rdiskN and never -d.
    @Test("REQ0083 the two passes use -n then -r3 on the raw node, with no direct I/O")
    func REQ0083_twoPassesUseTheRawNodeAndNoDirectIO() {
        #expect(rawDeviceNode(for: "disk8") == "/dev/rdisk8", "the raw character node, never /dev/diskN")

        let passes = ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: "/tmp/x.img",
            mapfile: "/tmp/x.img.mapfile",
            blockSize: 4096
        )

        #expect(passes.count == 2)
        #expect(passes[0].argv == [
            "caffeinate", "-dimsu", "ddrescue", "-n", "-b", "4096", "-O",
            "-K", "65536", "-T", "90", "/dev/rdisk8", "/tmp/x.img", "/tmp/x.img.mapfile",
        ])
        #expect(passes[1].argv == [
            "caffeinate", "-dimsu", "ddrescue", "-r3", "-b", "4096", "-O",
            "-K", "65536", "-T", "90", "/dev/rdisk8", "/tmp/x.img", "/tmp/x.img.mapfile",
        ])
        #expect(!passes[0].line.contains(" -d "))
        #expect(!passes[0].line.contains("/dev/disk8 "))
        #expect(!passes[1].line.contains(" -d "))
    }

    // REQ-0083: the block size comes from the device, not a constant.
    @Test("REQ0083 the block size is the collected device block size")
    func REQ0083_blockSizeComesFromTheDevice() {
        let passes = ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: "/tmp/x.img",
            mapfile: "/tmp/x.img.mapfile",
            blockSize: 512
        )
        #expect(passes[0].argv[5] == "512")
        #expect(passes[1].argv[5] == "512")
    }

    // REQ-0087: the ETA is a range from size and an assumed bus speed.
    @Test("REQ0087 the ETA is a range and states its assumption")
    func REQ0087_etaIsARange() throws {
        let range = try #require(etaRange(
            deviceBytes: 1_073_741_824,
            lowBytesPerSecond: 25_000_000,
            highBytesPerSecond: 30_000_000,
            basis: "assumed USB 25–30 MB/s"
        ))

        // 1 GiB / 30 MB/s and / 25 MB/s, hand-computed.
        #expect(abs(range.lowSeconds - 35.7913941333) < 0.001)
        #expect(abs(range.highSeconds - 42.94967296) < 0.001)
        #expect(range.basis.contains("assumed"))

        let bus = assumedBusSpeed(bus: "usb")
        #expect(bus.lowBytesPerSecond < bus.highBytesPerSecond)
        #expect(bus.basis.lowercased().contains("assumed"),
                "the range must say it is derived from an assumed speed")
    }

    // REQ-0084: the reference trigger from the bench (~200 B/s, ~9.9 MB left).
    @Test("REQ0084 the pass-2 reference case stops: ~200 B/s with ~9.9 MB left")
    func REQ0084_pass2StopReferenceCase() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deviceSize: Int64 = 320_000_000_000
        // 0.01% of the device is 32,000,000 B; the trailing ten minutes yield
        // only 120,000 B. 9,900,000 B remain at 200 B/s = 49,500 s, against
        // 7,200 s elapsed: 49,500 > 2 × 7,200.
        let latest: Int64 = deviceSize - 9_900_000
        let history = [
            Pass2Sample(time: now.addingTimeInterval(-7_200), rescuedBytes: latest - 200 * 7_200),
            Pass2Sample(time: now.addingTimeInterval(-600), rescuedBytes: latest - 200 * 600),
            Pass2Sample(time: now, rescuedBytes: latest),
        ]

        let decision = pass2StopDecision(history: history, deviceSize: deviceSize, now: now)
        let stop = try #require(decision.stop, "the reference case must stop")

        #expect(stop.marginalYieldBytes == 120_000)
        #expect(stop.remainingBytes == 9_900_000)
        #expect(stop.projectedRemainingSeconds == 49_500)
        #expect(stop.elapsedSeconds == 7_200)
    }

    // REQ-0084: both halves of the rule are required.
    @Test("REQ0084 a yield exactly at 0.01% is not below the threshold")
    func REQ0084_yieldAtTheThresholdKeepsGoing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deviceSize: Int64 = 1_000_000
        // 0.01% = 100 B. The trailing ten minutes yield exactly 100 B.
        let latest: Int64 = 900_000
        let history = [
            Pass2Sample(time: now.addingTimeInterval(-7_200), rescuedBytes: latest - 100),
            Pass2Sample(time: now.addingTimeInterval(-600), rescuedBytes: latest - 100),
            Pass2Sample(time: now, rescuedBytes: latest),
        ]

        let decision = pass2StopDecision(history: history, deviceSize: deviceSize, now: now)
        #expect(decision.stop == nil, "the rule is strictly less than 0.01%")
    }

    // REQ-0084: low yield alone is not enough; the projection must exceed
    // twice the elapsed time.
    @Test("REQ0084 low yield with a projection under 2x elapsed keeps going")
    func REQ0084_lowYieldButShortProjectionKeepsGoing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deviceSize: Int64 = 1_000_000
        // 50 B in ten minutes = 0.0833 B/s. 1,000 B remain -> 12,000 s
        // projected, less than 2 × 7,200 s.
        let latest: Int64 = deviceSize - 1_000
        let history = [
            Pass2Sample(time: now.addingTimeInterval(-7_200), rescuedBytes: latest - 600),
            Pass2Sample(time: now.addingTimeInterval(-600), rescuedBytes: latest - 50),
            Pass2Sample(time: now, rescuedBytes: latest),
        ]

        let decision = pass2StopDecision(history: history, deviceSize: deviceSize, now: now)
        #expect(decision.stop == nil)
    }

    @Test("REQ0084 low yield with a projection over 2x elapsed stops")
    func REQ0084_lowYieldLongProjectionStops() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deviceSize: Int64 = 1_000_000
        // 50 B in ten minutes = 0.0833 B/s. 2,000 B remain -> 24,000 s
        // projected, greater than 2 × 7,200 s.
        let latest: Int64 = deviceSize - 2_000
        let history = [
            Pass2Sample(time: now.addingTimeInterval(-7_200), rescuedBytes: latest - 600),
            Pass2Sample(time: now.addingTimeInterval(-600), rescuedBytes: latest - 50),
            Pass2Sample(time: now, rescuedBytes: latest),
        ]

        let decision = pass2StopDecision(history: history, deviceSize: deviceSize, now: now)
        #expect(try #require(decision.stop).remainingBytes == 2_000)
    }

    @Test("REQ0084 less than ten minutes of history cannot trigger the rule")
    func REQ0084_shortHistoryKeepsGoing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deviceSize: Int64 = 1_000_000
        let history = [
            Pass2Sample(time: now.addingTimeInterval(-599), rescuedBytes: 0),
            Pass2Sample(time: now, rescuedBytes: 1),
        ]

        #expect(pass2StopDecision(history: history, deviceSize: deviceSize, now: now).stop == nil)
    }

    // The plan says "resolve the destination volume's backing BSD disk via
    // diskutil info of the destination path"; on macOS 27.2 `diskutil info
    // <path>` exits 1, so the probe walks the mount's whole disk to its
    // physical store instead. These fixtures pin that walk.
    @Test("the backing disk of an APFS container is its physical store")
    func backingDiskResolvesAPFSContainer() throws {
        let container = try Data(contentsOf: URL(fileURLWithPath: fixturePath("diskutil-info-virtual-apfs.plist")))
        #expect(physicalBackingDisk(fromInfoPList: container, current: "disk1") == "disk0",
                "the synthesized container's DeviceNode is disk0")

        let physical = try Data(contentsOf: URL(fileURLWithPath: fixturePath("diskutil-info-internal.plist")))
        #expect(physicalBackingDisk(fromInfoPList: physical, current: "disk0") == "disk0",
                "a physical whole disk is its own backing")
    }

    @Test("a mount device path maps to its whole disk")
    func wholeDiskNameParsesSlices() {
        #expect(wholeDiskName(fromDevicePath: "/dev/disk3s5") == "disk3")
        #expect(wholeDiskName(fromDevicePath: "/dev/disk3s1s1") == "disk3")
        #expect(wholeDiskName(fromDevicePath: "/dev/disk8") == "disk8")
        #expect(wholeDiskName(fromDevicePath: "/dev/rdisk8") == "disk8")
        #expect(wholeDiskName(fromDevicePath: "/dev/notadisk") == nil)
    }
}
