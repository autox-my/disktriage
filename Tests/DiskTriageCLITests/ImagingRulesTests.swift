import Foundation
import Testing
import DiskTriageCore
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
    @Test("REQ0080_REQ0083_REQ0086 the two passes use -n then -r3 on the raw node, caffeinate, -O and -K, with no direct I/O")
    func REQ0080_REQ0083_REQ0086_twoPassesUseTheRawNodeAndNoDirectIO() {
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

    // REQ-0101: the limit is whole GiB (2^30 bytes), and at or above the device
    // size it is the full device, not a partial image.
    @Test("REQ0101 a limit is whole GiB and at or above the device is the full device")
    func REQ0101_limitIsGiBAndFullAtOrAboveTheDevice() {
        #expect(limitBytesForGiB(8) == 8_589_934_592, "GiB is 2^30 bytes")
        #expect(limitBytesForGiB(1) == 1_073_741_824)
        #expect(limitBytesForGiB(0) == nil, "a zero limit is not a limit")
        #expect(limitBytesForGiB(Int64.max) == nil, "an unrepresentable limit is refused")

        let device: Int64 = 10_000_000_000
        #expect(effectiveImageBytes(deviceBytes: device, limitBytes: 8_589_934_592) == 8_589_934_592)
        #expect(imageIsPartial(deviceBytes: device, limitBytes: 8_589_934_592) == true)

        let smallDevice: Int64 = 1_073_741_824
        #expect(effectiveImageBytes(deviceBytes: smallDevice, limitBytes: 8_589_934_592) == smallDevice,
                "a limit above the device is the full device")
        #expect(imageIsPartial(deviceBytes: smallDevice, limitBytes: 8_589_934_592) == false)
        #expect(imageIsPartial(deviceBytes: smallDevice, limitBytes: smallDevice) == false,
                "a limit equal to the device is the full device")
        #expect(imageIsPartial(deviceBytes: nil, limitBytes: 8_589_934_592) == false,
                "without a device size a partial image cannot be claimed")
        #expect(effectiveImageBytes(deviceBytes: nil, limitBytes: 8_589_934_592) == nil)
        #expect(effectiveImageBytes(deviceBytes: device, limitBytes: nil) == device)
    }

    // REQ-0102: both passes carry the byte limit as `-s` when partial, so
    // ddrescue reads exactly the first N bytes.
    @Test("REQ0102 both passes carry the byte limit as -s when partial")
    func REQ0102_bothPassesCarryTheByteLimit() {
        let partial = ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: "/tmp/x.img",
            mapfile: "/tmp/x.img.mapfile",
            blockSize: 4096,
            limitBytes: 8_589_934_592
        )
        #expect(partial[0].argv == [
            "caffeinate", "-dimsu", "ddrescue", "-n", "-b", "4096", "-O",
            "-K", "65536", "-T", "90", "-s", "8589934592",
            "/dev/rdisk8", "/tmp/x.img", "/tmp/x.img.mapfile",
        ])
        #expect(partial[1].argv == [
            "caffeinate", "-dimsu", "ddrescue", "-r3", "-b", "4096", "-O",
            "-K", "65536", "-T", "90", "-s", "8589934592",
            "/dev/rdisk8", "/tmp/x.img", "/tmp/x.img.mapfile",
        ])

        let full = ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: "/tmp/x.img",
            mapfile: "/tmp/x.img.mapfile",
            blockSize: 4096
        )
        #expect(!full[0].argv.contains("-s"), "a full image has no -s")
        #expect(!full[1].argv.contains("-s"))
    }

    // REQ-0103: when the image is partial, the free-space gate covers the
    // limit; its detail still names both the limit and the whole device.
    @Test("REQ0103 free space covers the limit when partial and names both sizes")
    func REQ0103_freeSpaceUsesTheLimitWhenPartial() {
        let source = ImageSource(
            bsd: "disk8",
            model: "Synthetic Bridge Disk",
            serial: "SYNTH0000ABCD",
            sizeBytes: 250_000_000_000,
            blockSize: 512
        )
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 10_737_418_240,          // 10 GiB free
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )

        let partial = assessDestination(facts: facts, source: source, limitBytes: 8_589_934_592)
        let partialFree = partial.first { $0.name == "free space" }
        #expect(partialFree?.outcome == .pass, "8 GiB is within 10 GiB free")
        #expect(partialFree?.detail.contains("8.0 GiB") == true, "the limit is the requirement")
        #expect(partialFree?.detail.contains("232.8 GiB") == true, "the device is still named")

        let full = assessDestination(facts: facts, source: source, limitBytes: nil)
        let fullFree = full.first { $0.name == "free space" }
        #expect(fullFree?.outcome == .refuse, "the full 232.8 GiB does not fit in 10 GiB")
        #expect(fullFree?.detail.contains("10.0 GiB") == true)
        #expect(fullFree?.detail.contains("232.8 GiB") == true)
    }

    // REQ-0105: the sidecar's recorded limit is part of the resume authority,
    // so a partial image is never silently continued as a full one or with a
    // different limit.
    @Test("REQ0105 the sidecar records the limit and refuses a different one")
    func REQ0105_sidecarRecordsAndComparesTheLimit() throws {
        let partial = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(model: "Expansion", serialSHA256: "abc123", sizeBytes: 100),
            limitBytes: 50
        )
        #expect(sidecarMatchesDevice(partial, model: "Expansion", serialHash: "abc123",
                                     sizeBytes: 100, limitBytes: 50) == true)
        #expect(sidecarMatchesDevice(partial, model: "Expansion", serialHash: "abc123",
                                     sizeBytes: 100, limitBytes: nil) == false,
                "a full resume of a partial image is refused")
        #expect(sidecarMatchesDevice(partial, model: "Expansion", serialHash: "abc123",
                                     sizeBytes: 100, limitBytes: 60) == false,
                "a different limit is refused")

        let full = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(model: "Expansion", serialSHA256: "abc123", sizeBytes: 100)
        )
        #expect(sidecarMatchesDevice(full, model: "Expansion", serialHash: "abc123",
                                     sizeBytes: 100, limitBytes: nil) == true)
        #expect(sidecarMatchesDevice(full, model: "Expansion", serialHash: "abc123",
                                     sizeBytes: 100, limitBytes: 50) == false,
                "a partial resume of a full image is refused")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(partial)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"limit_bytes\":50"), "the sidecar records the limit")

        let decoded = try JSONDecoder().decode(ImageSidecar.self, from: data)
        #expect(decoded.limitBytes == 50)
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
            lowBytesPerSecond: 30_000_000,
            highBytesPerSecond: 37_000_000,
            basis: "assumed USB 2: 30–37 MB/s"
        ))

        // 1 GiB / 37 MB/s and / 30 MB/s, hand-computed.
        #expect(abs(range.lowSeconds - 29.0200492973) < 0.001)
        #expect(abs(range.highSeconds - 35.7913941333) < 0.001)
        #expect(range.basis.contains("assumed"))

        let bus = assumedBusSpeed(bus: "usb")
        #expect(bus.lowBytesPerSecond == 30_000_000)
        #expect(bus.highBytesPerSecond == 37_000_000)
        #expect(bus.basis == "assumed USB 2: 30–37 MB/s (37 MB/s measured on a clean zone of the MiNaH drive)")
        #expect(bus.basis.lowercased().contains("assumed"),
                "the range must say it is derived from an assumed speed")
    }

    // REQ-0246
    @Test("REQ0246 the USB 2 assumption is 30–37 MB/s from the measured MiNaH zone")
    func REQ0246_usb2AssumptionUsesTheMeasuredRate() {
        let bus = assumedBusSpeed(bus: "usb")
        #expect(bus.lowBytesPerSecond == 30_000_000)
        #expect(bus.highBytesPerSecond == 37_000_000)
        #expect(bus.basis == "assumed USB 2: 30–37 MB/s (37 MB/s measured on a clean zone of the MiNaH drive)")

        // Bus unknown is the same measured basis, labelled as unknown.
        let unknown = assumedBusSpeed(bus: nil)
        #expect(unknown.lowBytesPerSecond == 30_000_000)
        #expect(unknown.highBytesPerSecond == 37_000_000)
        #expect(unknown.basis.contains("37 MB/s measured on a clean zone of the MiNaH drive"))
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

    // MARK: - The scope report's destination rule

    /// The 233.8 GiB device of the plan's transcript with 1.3 GiB free: the
    /// full-size rule refuses, and a scope report must not.
    private func scopeFacts(
        free: Int64 = 1_396_000_000,
        filesystem: String? = "apfs"
    ) -> DestinationFacts {
        DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: free,
            containerFilesystem: filesystem,
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
    }

    private func scopeSource() -> ImageSource {
        ImageSource(
            bsd: "disk8",
            model: "Synthetic Bridge Disk",
            serial: "SYNTH0000ABCD",
            sizeBytes: 251_000_193_024,   // 233.7601 GiB, formatted 233.8 GiB
            blockSize: 512
        )
    }

    // REQ-0233
    @Test("REQ0233 a scope report on APFS is judged by its metadata, not the device size")
    func REQ0233_scopeReportOnAPFSUsesTheMetadataRule() {
        let checks = assessDestination(
            facts: scopeFacts(),
            source: scopeSource(),
            scopeReport: true
        )
        let free = checks.first { $0.name == "free space" }
        #expect(free?.outcome == .pass, "1.3 GiB free is enough for a few MB: \(free?.detail ?? "missing")")
        #expect(free?.detail.contains("sparse image on apfs") == true, "\(free?.detail ?? "")")
        #expect(free?.detail.contains("metadata only") == true, "\(free?.detail ?? "")")
        #expect(free?.detail.contains("MiB") == true, "the metadata size is named: \(free?.detail ?? "")")
        #expect(free?.detail.contains("233.8 GiB") == false,
                "a metadata-only report does not need the device size")
    }

    // REQ-0234
    @Test("REQ0234 full and used-only runs keep the full-size free-space rule on APFS")
    func REQ0234_fullRunsKeepTheFullSizeRule() {
        // `--used-only` is a full imaging run with stage 2 skipped; it uses the
        // same destination assessment, so the absence of `scopeReport` is the
        // rule. A partial limit still uses the limit, as before.
        let full = assessDestination(facts: scopeFacts(), source: scopeSource())
        let free = full.first { $0.name == "free space" }
        #expect(free?.outcome == .refuse, "the full device does not fit: \(free?.detail ?? "missing")")
        #expect(free?.detail.contains("233.8 GiB") == true, "the device size is the requirement")
        #expect(free?.detail.contains("sparse image") == false)

        let partial = assessDestination(
            facts: scopeFacts(),
            source: scopeSource(),
            limitBytes: 8_589_934_592
        )
        let partialFree = partial.first { $0.name == "free space" }
        #expect(partialFree?.outcome == .refuse,
                "8 GiB still does not fit in 1.3 GiB; the partial rule is unchanged")
        #expect(partialFree?.detail.contains("8.0 GiB") == true)
    }

    // REQ-0235
    @Test("REQ0235 a scope report on a non-APFS destination keeps the full-size rule")
    func REQ0235_nonAPFSKeepsTheFullSizeRule() {
        for filesystem in ["hfs", "exfat", "msdos", nil] as [String?] {
            let checks = assessDestination(
                facts: scopeFacts(filesystem: filesystem),
                source: scopeSource(),
                scopeReport: true
            )
            let free = checks.first { $0.name == "free space" }
            #expect(free?.outcome == .refuse,
                    "\(filesystem ?? "unknown") is not sparse-capable: \(free?.detail ?? "missing")")
            #expect(free?.detail.contains("sparse image") == false,
                    "only APFS is sparse-capable")
        }
    }

    // REQ-0236
    @Test("REQ0236 a scope report requires at least 1 GiB free")
    func REQ0236_scopeReportHasAOneGiBFloor() {
        let floor: Int64 = 1_073_741_824
        // A 1 GiB device: 2 x its metadata budget is far below the floor, so
        // only the floor can refuse this half-gigabyte destination.
        let source = ImageSource(bsd: "disk8", sizeBytes: floor, blockSize: 512)

        let below = assessDestination(
            facts: scopeFacts(free: 536_870_912, filesystem: "apfs"),
            source: source,
            scopeReport: true
        )
        #expect(below.first { $0.name == "free space" }?.outcome == .refuse,
                "512 MiB is below the floor")

        let at = assessDestination(
            facts: scopeFacts(free: floor, filesystem: "apfs"),
            source: source,
            scopeReport: true
        )
        #expect(at.first { $0.name == "free space" }?.outcome == .pass,
                "exactly 1 GiB is enough")
    }

    @Test("the stage-0 scope budget is the bitmap bound plus fixed metadata")
    func scopeReportBudgetIsTheBitmapBound() {
        let device: Int64 = 251_000_193_024
        // 1 bit per 512-byte cluster (NTFS's smallest): 61,279,344 bytes,
        // rounded up to a byte; plus a 2 MiB fixed-metadata bound.
        let expected: Int64 = 61_279_344 + 2_097_152
        #expect(NTFSStage0ReadPlan.scopeReportByteBudget(deviceBytes: device) == expected)
        #expect(NTFSStage0ReadPlan.scopeReportByteBudget(deviceBytes: 0) == 0)
    }
}
