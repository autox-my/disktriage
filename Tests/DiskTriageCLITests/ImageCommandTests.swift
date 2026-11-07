import Foundation
import Testing
@testable import DiskTriageCLI

/// `disktriage image ... --dry-run` through the library seam: scripted
/// collectors and a scripted destination probe, so no test reads a device,
/// writes a file or runs ddrescue.
struct ImageCommandTests {

    // The fabricated fixture's serial is SYNTH0000ABCD; the hash below is the
    // independent SHA-256 of that string (`printf ... | shasum -a 256`), not a
    // value recomputed by the implementation.
    private static let syntheticSerial = "SYNTH0000ABCD"
    private static let syntheticSerialHash =
        "140a7381765287afbe4ee54904e08feabe9024b26a0a769284e63f5a81ee1b57"
    private static let syntheticSize: Int64 = 1_073_741_824
    private static let syntheticModel = "Synthetic Bridge Disk"

    // MARK: - Helpers

    private func serialExecutor() -> CLIExecutor {
        imageExecutor(info: fixtureText("diskutil-info-usb-synthetic-serial.plist"))
    }

    private func internalExecutor() -> CLIExecutor {
        imageExecutor(info: fixtureText("diskutil-info-internal.plist"))
    }

    private func goodFacts(backing: String = "disk0") -> DestinationFacts {
        DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: backing
        )
    }

    private func serialRun(
        _ extra: [String],
        executor: CLIExecutor? = nil,
        facts: DestinationFacts? = nil
    ) -> CLIResult {
        run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img"] + extra,
            executor: executor ?? serialExecutor(),
            destinationProbe: FakeImageProbe(facts: facts ?? goodFacts())
        )
    }

    private func internalRun(
        _ extra: [String],
        executor: CLIExecutor? = nil,
        facts: DestinationFacts? = nil
    ) -> CLIResult {
        run(
            arguments: ["image", "disk0", "--to", "/tmp/x.img"] + extra,
            executor: executor ?? internalExecutor(),
            destinationProbe: FakeImageProbe(facts: facts ?? goodFacts(backing: "disk8"))
        )
    }

    // MARK: - Triage attempt

    // REQ-0044: image runs the live triage pipeline and records the attempt.
    @Test("REQ0044 image runs the triage attempt for the device")
    func REQ0044_imageRunsTheTriageAttempt() {
        let executor = serialExecutor()
        let result = serialRun(["--confirm-serial", "ABCD"], executor: executor)

        #expect(result.exitCode == 0)
        #expect(executor.commands.contains { if case .ioregStatistics = $0 { return true }; return false })
        #expect(executor.commands.contains { if case .ioregMedia = $0 { return true }; return false })
        #expect(executor.commands.contains { if case .logShow = $0 { return true }; return false })
        #expect(executor.commands.contains { if case .smartctl = $0 { return true }; return false })
        #expect(result.stdout.contains("TRIAGE"), "the attempt is recorded in the plan")
        #expect(result.stdout.contains("attempted"))
        #expect(result.stderr.contains("collecting"), "progress stays on stderr")
    }

    // REQ-0046: --override skips the triage check, explicitly.
    @Test("REQ0046 --override skips the triage collection and says so")
    func REQ0046_overrideSkipsTheTriageCheck() {
        let executor = serialExecutor()
        let result = serialRun(
            ["--confirm-serial", "ABCD", "--override"],
            executor: executor
        )

        #expect(result.exitCode == 0)
        #expect(!executor.commands.contains { if case .ioregStatistics = $0 { return true }; return false })
        #expect(!executor.commands.contains { if case .logShow = $0 { return true }; return false })
        #expect(!executor.commands.contains { if case .smartctl = $0 { return true }; return false })
        #expect(result.stdout.contains("--override"))
        #expect(result.stdout.contains("skipped"))
    }

    // REQ-0045 / REQ-0049: an inconclusive, unsupported-media device is still
    // imaged, with the caveat that no health classification applies.
    @Test("REQ0045_REQ0049 unsupported media is not classified but is still imaged")
    func REQ0045_REQ0049_unsupportedMediaStillImagesWithCaveat() {
        let result = internalRun(["--confirm-size", "233"])

        #expect(result.exitCode == 0, "exit 20 does not block imaging")
        #expect(result.stdout.contains("exit 20"), "the triage attempt is recorded as inconclusive")
        #expect(result.stdout.contains("unsupported media"))
        #expect(result.stdout.contains("no health classification"))
        #expect(result.stdout.contains("caffeinate -dimsu ddrescue"))
    }

    // MARK: - Source identity confirmation

    // REQ-0050 / REQ-0051: model, serial and size are printed, and the last
    // four characters of the serial must be confirmed.
    @Test("REQ0050_REQ0051 the serial's last four characters must be confirmed")
    func REQ0050_REQ0051_serialConfirmationIsRequired() {
        let missing = serialRun([])
        #expect(missing.exitCode == 2, "missing confirmation is a usage error")
        #expect(missing.stdout.contains("MODEL"))
        #expect(missing.stdout.contains("Synthetic Bridge Disk"))
        #expect(missing.stdout.contains("SERIAL"))
        #expect(missing.stdout.contains(Self.syntheticSerial))
        #expect(missing.stdout.contains("SIZE"))
        #expect(missing.stdout.contains("--confirm-serial"))

        let wrong = serialRun(["--confirm-serial", "ZZZZ"])
        #expect(wrong.exitCode == 2)

        let right = serialRun(["--confirm-serial", "ABCD"])
        #expect(right.exitCode == 0)

        let lowercased = serialRun(["--confirm-serial", "abcd"])
        #expect(lowercased.exitCode == 0, "serial confirmation is case-insensitive")
    }

    // REQ-0052: when no serial is readable, the size is the confirmation
    // instead. It is never skipped.
    @Test("REQ0052 an unreadable serial requires --confirm-size in integer GiB")
    func REQ0052_sizeConfirmationWhenSerialIsUnreadable() {
        let missing = internalRun([])
        #expect(missing.exitCode == 2)
        #expect(missing.stdout.contains("--confirm-size"))
        #expect(missing.stdout.contains("233"), "251,000,193,024 B is 233 GiB truncated")

        let wrong = internalRun(["--confirm-size", "232"])
        #expect(wrong.exitCode == 2)

        let right = internalRun(["--confirm-size", "233"])
        #expect(right.exitCode == 0)
    }

    // MARK: - The command

    // REQ-0047 / REQ-0048 / REQ-0076 / REQ-0083: the exact two-pass command,
    // dry-run by default, with the mapfile beside the image.
    @Test("REQ0009_REQ0047_REQ0048_REQ0076_REQ0083 dry-run is the default and prints both passes")
    func REQ0009_REQ0047_REQ0048_REQ0076_REQ0083_dryRunPrintsTheCommand() {
        let result = serialRun(["--confirm-serial", "ABCD"])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("ddrescue -n -b 512"), "pass 1 is -n with the device block size")
        #expect(result.stdout.contains("ddrescue -r3 -b 512"), "pass 2 is -r3")
        #expect(result.stdout.contains("/dev/rdisk8"), "the raw character node")
        #expect(!result.stdout.contains("/dev/disk8 "), "never the buffered node")
        #expect(!result.stdout.contains("ddrescue -d"), "never direct I/O")
        #expect(result.stdout.contains("/tmp/x.img /tmp/x.img.mapfile"),
                "the mapfile defaults beside the image")
        #expect(result.stdout.contains("guard"), "the mount guard must run first")
        #expect(result.stdout.contains("Full Disk Access"), "FDA is named for the process that runs it")
    }

    @Test("REQ0076 --mapfile overrides the default mapfile path")
    func REQ0076_mapfileCanBeOverridden() {
        let result = serialRun(["--confirm-serial", "ABCD", "--mapfile", "/tmp/custom.map"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("/tmp/x.img /tmp/custom.map"))
    }

    // REQ-0087: the ETA is a stated range, never a promise.
    @Test("REQ0087 the plan prints an ETA range and its assumption")
    func REQ0087_etaRangeIsPrinted() {
        let result = serialRun(["--confirm-serial", "ABCD"])
        #expect(result.stdout.contains("ETA"))
        #expect(result.stdout.contains("assumed"))
        #expect(result.stdout.contains("–"), "a range, not a single number")
        #expect(result.stdout.contains("measured"),
                "the new USB 2 assumption cites the measured clean-zone rate")
    }

    // Non-dry-run refuses before any probe without the explicit consent flag.
    @Test("the non-dry-run path refuses without --accept-risk")
    func nonDryRunRequiresConsent() {
        let result = serialRun(["--confirm-serial", "ABCD", "--no-dry-run"])
        #expect(result.exitCode == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("--accept-risk"))
        #expect(result.stderr.contains("finish the drive off"))
    }

    // MARK: - Partial imaging (--limit)

    // REQ-0101: only a positive whole number of GiB is a limit; zero, a
    // fraction, a negative number and a non-number are usage errors.
    @Test("REQ0101 --limit takes only a positive whole number of GiB")
    func REQ0101_limitTakesAPositiveWholeNumberOfGiB() {
        for invalid in ["0", "-1", "1.5", "eight", "8GiB", ""] {
            let result = serialRun(["--confirm-serial", "ABCD", "--limit", invalid])
            #expect(result.exitCode == 2, "--limit '\(invalid)' is a usage error")
        }

        let missing = serialRun(["--confirm-serial", "ABCD", "--limit"])
        #expect(missing.exitCode == 2, "--limit without a value is a usage error")
    }

    // REQ-0101: a limit at or above the device size is the full device: no
    // PARTIAL label and no `-s`, because nothing would be truncated.
    @Test("REQ0101 a limit at or above the device size is the full device")
    func REQ0101_limitAtOrAboveTheDeviceIsTheFullDevice() {
        // The synthetic USB fixture is exactly 1 GiB.
        for limit in ["1", "2", "1000"] {
            let result = serialRun(["--confirm-serial", "ABCD", "--limit", limit])
            #expect(result.exitCode == 0, "--limit \(limit) is allowed")
            #expect(!result.stdout.contains("PARTIAL"), "--limit \(limit) is not partial")
            #expect(!result.stdout.contains(" -s "), "--limit \(limit) adds no -s")
        }
    }

    // REQ-0102: a partial plan puts `-s <bytes>` in both passes, and the human
    // plan and JSON say PARTIAL (N GiB of M GiB).
    @Test("REQ0102 a partial plan carries -s in both passes and says PARTIAL")
    func REQ0102_partialPlanCarriesDashS() throws {
        // 251,000,193,024 B = 233.7601 GiB, formatted 233.8 GiB.
        let result = internalRun(["--confirm-size", "233", "--limit", "8"])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains(
            "ddrescue -n -b 4096 -O -K 65536 -T 90 -s 8589934592 /dev/rdisk0 /tmp/x.img /tmp/x.img.mapfile"
        ), "pass 1 carries the byte limit")
        #expect(result.stdout.contains(
            "ddrescue -r3 -b 4096 -O -K 65536 -T 90 -s 8589934592 /dev/rdisk0 /tmp/x.img /tmp/x.img.mapfile"
        ), "pass 2 carries the byte limit")
        #expect(result.stdout.contains("PARTIAL (8.0 GiB of 233.8 GiB)"),
                "the plan says how much of the device is imaged")

        let json = internalRun(["--confirm-size", "233", "--limit", "8", "--json"])
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        )
        let limit = try #require(object["limit"] as? [String: Any])
        #expect(limit["bytes"] as? Int64 == 8_589_934_592 || limit["bytes"] as? Int == 8_589_934_592)
        #expect(limit["partial"] as? Bool == true)
        #expect(limit["description"] as? String == "PARTIAL (8.0 GiB of 233.8 GiB)")
        let passes = try #require(object["passes"] as? [String])
        #expect(passes.allSatisfy { $0.contains("-s 8589934592") })
    }

    // REQ-0103: the free-space gate uses the limit when partial, and a refusal
    // still names both the limit and the whole device.
    @Test("REQ0103 free space is checked against the limit when partial")
    func REQ0103_freeSpaceUsesTheLimitWhenPartial() {
        let tenGiB: Int64 = 10 * 1_073_741_824
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: tenGiB,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk8"
        )

        let partial = internalRun(["--confirm-size", "233", "--limit", "8"], facts: facts)
        #expect(partial.exitCode == 0, "8 GiB fits in 10 GiB free")
        #expect(partial.stdout.contains("10.0 GiB free"))
        #expect(partial.stdout.contains("8.0 GiB needed"))
        #expect(partial.stdout.contains("233.8 GiB"), "the whole device is still named")

        let full = internalRun(["--confirm-size", "233"], facts: facts)
        #expect(full.exitCode == 2, "the full 233.8 GiB does not fit in 10 GiB")
        #expect(full.stdout.contains("free"))
        #expect(full.stdout.contains("10.0 GiB"))
        #expect(full.stdout.contains("233.8 GiB"))
    }

    // REQ-0233 / REQ-0234: a scope-report dry run on APFS passes the
    // metadata free-space rule while full and --used-only runs keep the
    // full-size rule on the same 1.3 GiB destination.
    @Test("REQ0233_REQ0234 a scope report fits where a full run does not")
    func REQ0233_REQ0234_scopeReportFreeSpaceOnAPFS() {
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 1_396_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk8"
        )

        let report = internalRun(["--confirm-size", "233", "--scope-report"], facts: facts)
        #expect(report.exitCode == 0, "\(report.stdout)\(report.stderr)")
        #expect(report.stdout.contains(
            "sparse image on apfs: scope report writes metadata only"
        ), "\(report.stdout)")

        let full = internalRun(["--confirm-size", "233"], facts: facts)
        #expect(full.exitCode == 2, "the full device still does not fit: \(full.stdout)")
        #expect(full.stdout.contains("233.8 GiB"), "the device size is still the requirement")

        let usedOnly = internalRun(["--confirm-size", "233", "--used-only"], facts: facts)
        #expect(usedOnly.exitCode == 2, "--used-only is a full imaging run: \(usedOnly.stdout)")
        #expect(usedOnly.stdout.contains("233.8 GiB"))
    }

    // REQ-0104: the size confirmation is the whole device, never the limit.
    @Test("REQ0104 the size confirmation names the whole device, not the limit")
    func REQ0104_confirmationNamesTheWholeDevice() {
        let limitAsConfirmation = internalRun(["--confirm-size", "8", "--limit", "8"])
        #expect(limitAsConfirmation.exitCode == 2, "the limit is not the identity")
        #expect(limitAsConfirmation.stdout.contains("--confirm-size 233"),
                "the instruction still names the 233 GiB device")

        let deviceAsConfirmation = internalRun(["--confirm-size", "233", "--limit", "8"])
        #expect(deviceAsConfirmation.exitCode == 0)
        #expect(deviceAsConfirmation.stdout.contains("size confirmed (233 GiB)"))

        let serialConfirmation = serialRun(["--confirm-serial", "ABCD", "--limit", "1"])
        #expect(serialConfirmation.exitCode == 0)
    }

    // MARK: - Destination checks

    // REQ-0079: on the source disk.
    @Test("REQ0079 a destination on the source disk is refused")
    func REQ0079_destinationOnSourceDiskIsRefused() {
        let result = serialRun(
            ["--confirm-serial", "ABCD"],
            facts: goodFacts(backing: "disk8")
        )
        #expect(result.exitCode == 2)
        #expect(result.stdout.contains("source disk"))
        #expect(result.stdout.contains("ddrescue"), "the dry-run still prints the command")
    }

    @Test("REQ0079 insufficient free space is refused")
    func REQ0079_insufficientFreeSpaceIsRefused() {
        var facts = goodFacts()
        facts = DestinationFacts(
            destinationExists: facts.destinationExists,
            mapfileExists: facts.mapfileExists,
            freeBytes: 100,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
        let result = serialRun(["--confirm-serial", "ABCD"], facts: facts)
        #expect(result.exitCode == 2)
        #expect(result.stdout.contains("free"))
    }

    @Test("REQ0079 FAT32 is refused and an unwritable destination is refused")
    func REQ0079_fat32AndUnwritableAreRefused() {
        let fat = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "msdos",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
        let fatResult = serialRun(["--confirm-serial", "ABCD"], facts: fat)
        #expect(fatResult.exitCode == 2)
        #expect(fatResult.stdout.contains("4 GiB"))

        let readOnly = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: false,
            backingWholeDisk: "disk0"
        )
        let readOnlyResult = serialRun(["--confirm-serial", "ABCD"], facts: readOnly)
        #expect(readOnlyResult.exitCode == 2)
        #expect(readOnlyResult.stdout.contains("not writable"))
    }

    // REQ-0078: an existing image with no mapfile is never overwritten.
    @Test("REQ0078 an existing image without a mapfile is refused")
    func REQ0078_existingImageWithoutMapfileIsRefused() {
        let facts = DestinationFacts(
            destinationExists: true,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
        let result = serialRun(["--confirm-serial", "ABCD"], facts: facts)
        #expect(result.exitCode == 2)
        #expect(result.stdout.contains("mapfile"))
    }

    // REQ-0077: a resume is allowed only with a sidecar naming this device.
    @Test("REQ0077 a matching sidecar resumes; a mismatch or missing sidecar is refused")
    func REQ0077_resumeRequiresMatchingSidecar() {
        let matching = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(
                model: Self.syntheticModel,
                serialSHA256: Self.syntheticSerialHash,
                sizeBytes: Self.syntheticSize
            )
        )

        let resumed = serialRun(["--confirm-serial", "ABCD"], facts: resumeFacts(sidecar: matching))
        #expect(resumed.exitCode == 0, "the image and mapfile belong to this device")

        let wrong = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(
                model: Self.syntheticModel,
                serialSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
                sizeBytes: Self.syntheticSize
            )
        )
        let mismatch = serialRun(["--confirm-serial", "ABCD"], facts: resumeFacts(sidecar: wrong))
        #expect(mismatch.exitCode == 2)
        #expect(mismatch.stdout.contains("different device"))

        let missing = serialRun(["--confirm-serial", "ABCD"], facts: resumeFacts(sidecar: nil))
        #expect(missing.exitCode == 2)
        #expect(missing.stdout.contains("no sidecar"))
    }

    // MARK: - JSON and usage

    @Test("REQ0056 --json carries the same plan")
    func REQ0056_jsonCarriesThePlan() throws {
        let result = serialRun(["--confirm-serial", "ABCD", "--json"])
        #expect(result.exitCode == 0)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["dry_run"] as? Bool == true)
        #expect(object["status"] as? String == "ok")
        let passes = try #require(object["passes"] as? [String])
        #expect(passes.count == 2)
        let source = try #require(object["source"] as? [String: Any])
        #expect(source["bsd"] as? String == "disk8")
        let triage = try #require(object["triage"] as? [String: Any])
        #expect(triage["attempted"] as? Bool == true)
    }

    @Test("image usage errors exit 2, and --help exits 0")
    func usageErrorsAndHelp() {
        #expect(run(arguments: ["image"]).exitCode == 2)
        #expect(run(arguments: ["image", "disk8"]).exitCode == 2)
        #expect(run(arguments: ["image", "disk8", "--to"]).exitCode == 2)
        #expect(run(arguments: ["image", "disk8", "--to", "/tmp/x.img", "--wat"]).exitCode == 2)

        let help = run(arguments: ["image", "--help"])
        #expect(help.exitCode == 0)
        #expect(help.stdout.contains("usage: disktriage image"))
    }

    // MARK: - Fixtures

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
}

// MARK: - Scripted seams

struct FakeImageProbe: ImageDestinationProbing {
    let facts: DestinationFacts

    func probe(destination: String, mapfile: String) -> DestinationFacts {
        facts
    }
}

private func imageExecutor(info: String) -> CLIExecutor {
    CLIExecutor { command in
        switch command {
        case .diskutilInfo:
            return .ok(info)
        case .ioregStatistics:
            return .ok(fixtureText("ioreg-internal-driver.txt"))
        case .ioregMedia:
            return .ok(fixtureText("ioreg-iomedia-internal.txt"))
        case .logShow:
            return .ok(fixtureText("kernel-log-healthy-compact.txt"))
        case .smartctl:
            return .ok(#"{"smartctl":{"exit_status":0}}"#)
        default:
            return .ok("")
        }
    }
}

private func fixtureText(_ name: String) -> String {
    (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
}
