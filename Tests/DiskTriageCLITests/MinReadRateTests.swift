import Foundation
import Testing
@testable import DiskTriageCLI
@testable import DiskTriageCollectors

/// `disktriage image --min-read-rate <MB/s>` (diskdoctor.md §8, "Defer slow
/// zones"). The expectations are the plan's: 10 MB/s default on rotational or
/// unknown media, 0 (flag omitted) for SSD/flash/NVMe or unsupported media,
/// and 1 MB/s = 1,000,000 bytes/s as `ddrescue -a` takes bytes/s.
struct MinReadRateTests {

    private static let syntheticSerial = "SYNTH0000ABCD"
    private static let syntheticSerialHash =
        "140a7381765287afbe4ee54904e08feabe9024b26a0a769284e63f5a81ee1b57"
    private static let syntheticSize: Int64 = 1_073_741_824
    private static let syntheticModel = "Synthetic Bridge Disk"

    // MARK: - Pure rules

    // REQ-0179: pass 1 carries `-a <bytes/s>`; pass 2 never does.
    @Test("REQ0179 the command table puts -a and its bytes on pass 1 only")
    func REQ0179_minReadRateAppearsInPassOneOnly() {
        let withRate = ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: "/tmp/x.img",
            mapfile: "/tmp/x.img.mapfile",
            blockSize: 512,
            minReadRateBytesPerSecond: 10_000_000
        )
        #expect(withRate[0].argv == [
            "caffeinate", "-dimsu", "ddrescue", "-n", "-b", "512", "-O",
            "-K", "65536", "-T", "90", "-a", "10000000",
            "/dev/rdisk8", "/tmp/x.img", "/tmp/x.img.mapfile",
        ])
        #expect(withRate[1].argv == [
            "caffeinate", "-dimsu", "ddrescue", "-r3", "-b", "512", "-O",
            "-K", "65536", "-T", "90",
            "/dev/rdisk8", "/tmp/x.img", "/tmp/x.img.mapfile",
        ])

        let withoutRate = ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: "/tmp/x.img",
            mapfile: "/tmp/x.img.mapfile",
            blockSize: 512
        )
        #expect(!withoutRate[0].argv.contains("-a"))
        #expect(!withoutRate[1].argv.contains("-a"))
    }

    // REQ-0179: 1 MB/s is 1,000,000 bytes/s, and 0 disables the flag.
    @Test("REQ0179 the unit is 1000000 bytes per MB/s and 0 disables")
    func REQ0179_minReadRateUsesDecimalMegabytes() {
        #expect(minReadRateBytesPerSecond(megabytesPerSecond: 1) == 1_000_000)
        #expect(minReadRateBytesPerSecond(megabytesPerSecond: 10) == 10_000_000)
        #expect(minReadRateBytesPerSecond(megabytesPerSecond: 10_000) == 10_000_000_000)
        #expect(minReadRateBytesPerSecond(megabytesPerSecond: 0) == nil)
    }

    // REQ-0180: HDD and unknown default to 10 MB/s; SSD, flash, SD and NVMe
    // (including an unknown media on an NVMe bus) are disabled.
    @Test("REQ0180 the default is 10 MB/s only for rotational or unknown media")
    func REQ0180_defaultFollowsTheMediaClassification() {
        #expect(defaultMinReadRateMBps(media: "hdd", bus: "usb") == 10)
        #expect(defaultMinReadRateMBps(media: "unknown", bus: "usb") == 10)
        #expect(defaultMinReadRateMBps(media: nil, bus: nil) == 10)

        #expect(defaultMinReadRateMBps(media: "ssd", bus: "sata") == 0)
        #expect(defaultMinReadRateMBps(media: "flash", bus: nil) == 0)
        #expect(defaultMinReadRateMBps(media: "sd", bus: nil) == 0)
        #expect(defaultMinReadRateMBps(media: "sdcard", bus: nil) == 0)
        #expect(defaultMinReadRateMBps(media: "unknown", bus: "nvme") == 0)
        #expect(defaultMinReadRateMBps(media: "hdd", bus: "nvme") == 0,
                "an NVMe bus is unsupported media regardless of the media key")
    }

    // REQ-0183: the value is informational, never part of the resume identity.
    @Test("REQ0183 a sidecar's min read rate never changes the resume decision")
    func REQ0183_sidecarDoesNotCheckMinReadRate() {
        let sidecar = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(
                model: Self.syntheticModel,
                serialSHA256: Self.syntheticSerialHash,
                sizeBytes: Self.syntheticSize
            ),
            minReadRateBytesPerSecond: 10_000_000
        )
        #expect(sidecarMatchesDevice(
            sidecar,
            model: Self.syntheticModel,
            serialHash: Self.syntheticSerialHash,
            sizeBytes: Self.syntheticSize
        ) == true, "a different min read rate is still the same device")
    }

    // REQ-0184: the sidecar records the resolved value, informational only.
    @Test("REQ0184 the sidecar records the min read rate under its own key")
    func REQ0184_sidecarRecordsTheMinReadRate() throws {
        let sidecar = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(model: "Expansion", serialSHA256: "abc123", sizeBytes: 100),
            minReadRateBytesPerSecond: 10_000_000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sidecar)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"min_read_rate_bytes_per_second\":10000000"))
        #expect(try JSONDecoder().decode(ImageSidecar.self, from: data)
            .minReadRateBytesPerSecond == 10_000_000)
    }

    // MARK: - CLI flag parsing

    // REQ-0178: only a non-negative integer MB/s up to 10000 is accepted.
    @Test("REQ0178 --min-read-rate refuses a non-number, a negative and over 10000")
    func REQ0178_flagParsing() {
        for invalid in ["abc", "-1", "10001", "1.5", "", "ten"] {
            let result = serialRun(["--confirm-serial", "ABCD", "--min-read-rate", invalid])
            #expect(result.exitCode == 2, "--min-read-rate '\(invalid)' is a usage error")
        }

        let missing = serialRun(["--confirm-serial", "ABCD", "--min-read-rate"])
        #expect(missing.exitCode == 2, "a missing value is a usage error")

        for valid in ["0", "1", "10", "10000"] {
            let result = serialRun(["--confirm-serial", "ABCD", "--min-read-rate", valid])
            #expect(result.exitCode == 0, "--min-read-rate '\(valid)' is allowed")
        }
    }

    // REQ-0180 / REQ-0181: the default and the explicit 0 at the dry-run seam.
    @Test("REQ0180_REQ0181 the dry-run command follows the media default and 0 disables")
    func REQ0180_REQ0181_dryRunDefaultsAndZero() {
        let hdd = serialRun(["--confirm-serial", "ABCD"])
        #expect(hdd.exitCode == 0)
        #expect(hdd.stdout.contains("-a 10000000"), "rotational media defaults to 10 MB/s")
        #expect(hdd.stdout.contains("MIN RATE"))
        #expect(hdd.stdout.contains("10000000"))

        let hddDisabled = serialRun(["--confirm-serial", "ABCD", "--min-read-rate", "0"])
        #expect(hddDisabled.exitCode == 0)
        #expect(!hddDisabled.stdout.contains("-a 10000000"), "0 disables the flag")
        #expect(hddDisabled.stdout.contains("MIN RATE"))
        #expect(hddDisabled.stdout.contains("disabled"))

        let ssd = internalRun(["--confirm-size", "233"])
        #expect(ssd.exitCode == 0)
        #expect(!ssd.stdout.contains("-a 10000000"), "an SSD does not defer slow zones by default")
        #expect(!ssd.stdout.contains("-a 0"), "disabled is never `-a 0`")
        #expect(ssd.stdout.contains("MIN RATE"))

        let ssdOptIn = internalRun(["--confirm-size", "233", "--min-read-rate", "4"])
        #expect(ssdOptIn.exitCode == 0)
        #expect(ssdOptIn.stdout.contains("-a 4000000"), "the explicit flag overrides the default")
    }

    // REQ-0182: the JSON plan carries the key as an integer or null.
    @Test("REQ0182 the JSON plan carries min_read_rate_bytes_per_second")
    func REQ0182_jsonPlanKey() throws {
        let hdd = serialRun(["--confirm-serial", "ABCD", "--json"])
        let hddObject = try #require(
            try JSONSerialization.jsonObject(with: Data(hdd.stdout.utf8)) as? [String: Any]
        )
        #expect(hddObject["min_read_rate_bytes_per_second"] as? Int == 10_000_000)
        let passes = try #require(hddObject["passes"] as? [String])
        #expect(passes[0].contains("-a 10000000"))
        #expect(!passes[1].contains("-a"))

        let ssd = internalRun(["--confirm-size", "233", "--json"])
        let ssdObject = try #require(
            try JSONSerialization.jsonObject(with: Data(ssd.stdout.utf8)) as? [String: Any]
        )
        #expect(ssdObject["min_read_rate_bytes_per_second"] is NSNull,
                "disabled is null, never invented as 0")
    }

    // REQ-0183: resuming with another value is allowed; the sidecar records the
    // old value but the device identity still matches.
    @Test("REQ0183 a resume with a different min read rate is allowed")
    func REQ0183_resumeWithAChangedValueIsAllowed() {
        let sidecar = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(
                model: Self.syntheticModel,
                serialSHA256: Self.syntheticSerialHash,
                sizeBytes: Self.syntheticSize
            ),
            minReadRateBytesPerSecond: 10_000_000
        )
        let result = serialRun(
            ["--confirm-serial", "ABCD", "--min-read-rate", "5"],
            facts: resumeFacts(sidecar: sidecar)
        )
        #expect(result.exitCode == 0, "changing the min read rate must not refuse a resume")
        #expect(result.stdout.contains("-a 5000000"))
    }

    // MARK: - End to end through the fake ddrescue seam

    // REQ-0179 / REQ-0184: the argv the supervisor gives the fake includes
    // `-a 10000000` in pass 1 only, and the sidecar records it.
    @Test("REQ0179_REQ0184 the supervised passes defer slow zones in pass 1 only")
    func REQ0179_REQ0184_supervisedArgvAndSidecar() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()

        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: 1_073_741_824, total: 1_073_741_824, pass: 1, finished: true)
                return nil
            },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = [
            {
                writeMapfile(mapfile, rescued: 1_073_741_824, total: 1_073_741_824, pass: 2, finished: true)
                return nil
            },
        ]
        launcher.handles = [pass1, pass2]

        let result = DiskTriageCLI.image(
            ["disk8", "--to", image, "--no-dry-run", "--accept-risk",
             "--confirm-serial", "ABCD", "--limit", "1"],
            executor: scriptedExecutor(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            destinationProbe: FakeImageProbe(facts: emptyFacts()),
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: ImagingDependencies(
                environment: FakeImagingEnvironment(),
                launcher: launcher
            )
        )

        #expect(result.exitCode == 0)
        #expect(launcher.launches.count == 2)
        #expect(containsSequence(launcher.launches[0].argv, ["-a", "10000000"]),
                "pass 1 defers slow zones at the 10 MB/s default")
        #expect(!launcher.launches[1].argv.contains("-a"),
                "pass 2 must come back to the deferred zones")

        let sidecar = try decodeSidecar(image + ".disktriage.json")
        #expect(sidecar.minReadRateBytesPerSecond == 10_000_000)
        #expect(result.stdout.contains("MIN RATE"))
        #expect(result.stdout.contains("10000000"))
    }

    // REQ-0182: the final summary reports the resolved value, and its JSON is
    // the same number.
    @Test("REQ0182 the final summary reports the min read rate")
    func REQ0182_finalSummaryReportsTheValue() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            { writeMapfile(mapfile, rescued: 1_073_741_824, total: 1_073_741_824, pass: 1, finished: true); return nil },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = [
            { writeMapfile(mapfile, rescued: 1_073_741_824, total: 1_073_741_824, pass: 2, finished: true); return nil },
        ]
        launcher.handles = [pass1, pass2]

        let result = DiskTriageCLI.image(
            ["disk8", "--to", image, "--no-dry-run", "--accept-risk",
             "--confirm-serial", "ABCD", "--min-read-rate", "7", "--json"],
            executor: scriptedExecutor(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            destinationProbe: FakeImageProbe(facts: emptyFacts()),
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: ImagingDependencies(
                environment: FakeImagingEnvironment(),
                launcher: launcher
            )
        )

        #expect(result.exitCode == 0)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["min_read_rate_bytes_per_second"] as? Int == 7_000_000)
    }

    // MARK: - Helpers

    private func serialRun(
        _ extra: [String],
        facts: DestinationFacts? = nil
    ) -> CLIResult {
        run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img"] + extra,
            executor: executor(info: "diskutil-info-usb-synthetic-serial.plist"),
            destinationProbe: FakeImageProbe(facts: facts ?? emptyFacts())
        )
    }

    private func internalRun(_ extra: [String]) -> CLIResult {
        run(
            arguments: ["image", "disk0", "--to", "/tmp/x.img"] + extra,
            executor: executor(info: "diskutil-info-internal.plist"),
            destinationProbe: FakeImageProbe(facts: DestinationFacts(
                destinationExists: false,
                mapfileExists: false,
                freeBytes: 2_000_000_000_000,
                containerFilesystem: "apfs",
                parentIsWritable: true,
                backingWholeDisk: "disk8"
            ))
        )
    }

    private func emptyFacts() -> DestinationFacts {
        DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
    }

    private func resumeFacts(sidecar: ImageSidecar?) -> DestinationFacts {
        DestinationFacts(
            destinationExists: true,
            mapfileExists: true,
            sidecar: sidecar,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
    }

    private func executor(info: String) -> CLIExecutor {
        let text = (try? String(contentsOfFile: fixturePath(info), encoding: .utf8)) ?? ""
        return CLIExecutor { command in
            switch command {
            case .diskutilInfo:
                return .ok(text)
            case .ioregStatistics:
                return .ok((try? String(contentsOfFile: fixturePath("ioreg-internal-driver.txt"), encoding: .utf8)) ?? "")
            case .ioregMedia:
                return .ok((try? String(contentsOfFile: fixturePath("ioreg-iomedia-internal.txt"), encoding: .utf8)) ?? "")
            case .logShow:
                return .ok((try? String(contentsOfFile: fixturePath("kernel-log-healthy-compact.txt"), encoding: .utf8)) ?? "")
            case .smartctl:
                return .ok(#"{"smartctl":{"exit_status":0}}"#)
            default:
                return .ok("")
            }
        }
    }
}

private func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count) {
        if Array(haystack[start..<(start + needle.count)]) == needle { return true }
    }
    return false
}
