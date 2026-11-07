import Foundation
import Darwin
import Testing
@testable import DiskTriageCLI
@testable import DiskTriageCollectors
import DiskTriageCore

/// P3b: the supervised two-pass image run, driven through the injected seams.
/// No test opens a device: the "device" is a regular file path, and ddrescue is
/// a fake that rewrites a real mapfile.
struct ImagingExecutionTests {

    private static let size: Int64 = 1_073_741_824
    private static let serialHash =
        "140a7381765287afbe4ee54904e08feabe9024b26a0a769284e63f5a81ee1b57"

    // MARK: - Happy path

    @Test("REQ0076_REQ0077_REQ0083 the sidecar exists before the first read and both passes run")
    func REQ0076_REQ0077_REQ0083_sidecarBeforeReadAndTwoPasses() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let environment = FakeImagingEnvironment()
        let launcher = FakeDdrescueLauncher()

        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: 512_000_000, total: Self.size, pass: 1)
                return nil
            },
            {
                writeMapfile(mapfile, rescued: Self.size, total: Self.size, pass: 1, finished: true)
                return nil
            },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = [
            { writeMapfile(mapfile, rescued: Self.size, total: Self.size, pass: 2, finished: true); return nil },
        ]
        launcher.handles = [pass1, pass2]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: environment,
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination())
        )

        #expect(result.exitCode == 0)
        #expect(launcher.launches.count == 2, "one launch per pass")
        #expect(launcher.launches.filter { !$0.sidecarExisted }.isEmpty,
                "the sidecar is written before the first read")
        #expect(launcher.launches[0].argv.contains("-n"), "pass 1 is -n")
        #expect(launcher.launches[1].argv.contains("-r3"), "pass 2 is -r3")
        #expect(launcher.launches[0].argv == ddrescuePasses(
            rawDevice: "/dev/rdisk8",
            image: image,
            mapfile: mapfile,
            blockSize: 512,
            // The USB fixture is rotational, so the new slow-zone default
            // puts `-a 10000000` in pass 1 (REQ-0180).
            minReadRateBytesPerSecond: 10_000_000
        )[0].argv, "pass 1 is exactly the dry-run command")

        let sidecar = try decodeSidecar(image + ".disktriage.json")
        #expect(sidecar.device.sizeBytes == Self.size)
        #expect(sidecar.device.serialSHA256 == Self.serialHash)
        #expect(sidecar.device.model == "Synthetic Bridge Disk")
        #expect(sidecar.createdAt != nil, "the start time is recorded")
        #expect(sidecar.command?.joined(separator: " ").contains("ddrescue -n") == true,
                "the command is recorded")

        #expect(result.stdout.contains("RESCUED"))
        #expect(result.stdout.contains("STOPPED"))
        #expect(result.stdout.contains("complete"))
        #expect(result.stdout.contains("zero-filled"), "the honest damage statement")
        #expect(result.stdout.contains("damage report"), "the next step is named")
        #expect(result.stdout.contains("RESUME") == false, "a complete image needs no resume")
    }

    @Test("--json carries the final summary")
    func jsonSummary() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: Self.size, total: Self.size, pass: 1, finished: true)
                return nil
            },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = [
            {
                writeMapfile(mapfile, rescued: Self.size, total: Self.size, pass: 2, finished: true)
                return nil
            },
        ]
        launcher.handles = [pass1, pass2]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination()),
            extra: ["--json"]
        )

        #expect(result.exitCode == 0)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["status"] as? String == "complete")
        #expect(object["stopped"] as? String == "complete")
        #expect(object["pass_reached"] as? Int == 2)
        #expect(object["rescued_bytes"] as? Int64 != nil || object["rescued_bytes"] as? Int != nil)
        #expect(object["remaining_extents"] as? Int == 0)
        #expect(object["resume_command"] == nil)
    }

    // MARK: - Consent and preconditions

    @Test("reading a failing drive is refused without --accept-risk")
    func consentIsRequired() {
        // The refusal must happen before anything probes the machine, and
        // certainly before a launcher exists.
        let environment = FakeImagingEnvironment()
        let launcher = FakeDdrescueLauncher()
        let dependencies = ImagingDependencies(environment: environment, launcher: launcher)
        let result = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--no-dry-run", "--confirm-serial", "ABCD"],
            executor: scriptedExecutor(),
            destinationProbe: FakeImageProbe(facts: emptyDestination()),
            imaging: dependencies
        )
        #expect(result.exitCode == 2, "a missing flag is a usage error")
        #expect(result.stderr.contains("--accept-risk"))
        #expect(result.stderr.contains("finish the drive off"), "the plan's risk wording")
        #expect(result.stdout.isEmpty)
        #expect(environment.probeCount == 0, "the consent refusal probes nothing")
        #expect(launcher.launches.isEmpty)
    }

    @Test("imaging a raw device needs root")
    func rootIsRequired() {
        let environment = FakeImagingEnvironment()
        environment.root = false
        let launcher = FakeDdrescueLauncher()
        let result = execute(environment: environment, launcher: launcher)

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("root"))
        #expect(result.stderr.contains("sudo"))
        #expect(launcher.launches.isEmpty, "nothing is launched before the precondition")
    }

    @Test("a mount guard must be in effect unless --no-guard-check is given")
    func guardIsRequired() {
        let environment = FakeImagingEnvironment()
        environment.guardValue = .none
        let refusedLauncher = FakeDdrescueLauncher()
        let refused = execute(environment: environment, launcher: refusedLauncher)
        #expect(refused.exitCode == 30)
        #expect(refused.stderr.contains("guard"))
        #expect(refused.stderr.contains("--no-guard-check"))
        #expect(refusedLauncher.launches.isEmpty)

        let allowedLauncher = FakeDdrescueLauncher()
        allowedLauncher.handles = [FakeDdrescueProcess(), FakeDdrescueProcess()]
        let allowed = execute(
            environment: environment,
            launcher: allowedLauncher,
            extra: ["--no-guard-check"]
        )
        #expect(allowed.exitCode == 0)
        #expect(allowed.stderr.contains("probe read"), "the warning says a read may already have happened")
    }

    @Test("a stopped diskarbitrationd or a running guard satisfies the guard check")
    func guardStatesPass() {
        for state in [GuardState.daemonStopped, .guardRunning] {
            let environment = FakeImagingEnvironment()
            environment.guardValue = state
            let launcher = FakeDdrescueLauncher()
            launcher.handles = [FakeDdrescueProcess(), FakeDdrescueProcess()]
            #expect(execute(environment: environment, launcher: launcher).exitCode == 0, "\(state)")
        }
    }

    @Test("REQ0043 a denied Full Disk Access blocks imaging with the degraded message")
    func REQ0043_deniedFDABlocks() {
        let environment = FakeImagingEnvironment()
        environment.fda = FDAStatus(
            state: .denied,
            evidence: .failed(errno: 1, message: "Operation not permitted"),
            needsSudo: false,
            tccPassed: false,
            detail: "EPERM 1"
        )
        let launcher = FakeDdrescueLauncher()
        let result = execute(environment: environment, launcher: launcher)

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("raw device access denied (TCC)"))
        #expect(result.stderr.contains("Imaging needs Full Disk Access"))
        #expect(launcher.launches.isEmpty)
    }

    @Test("ddrescue must be present")
    func ddrescueMustBePresent() {
        let environment = FakeImagingEnvironment()
        environment.ddrescue = false
        let launcher = FakeDdrescueLauncher()
        let result = execute(environment: environment, launcher: launcher)
        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("ddrescue"))
        #expect(launcher.launches.isEmpty)
    }

    // MARK: - The stop rule

    @Test("REQ0085 the pass-2 stop rule SIGINTs ddrescue and prints what remains and the resume command")
    func REQ0085_stopRuleInterruptsAndReports() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let clock = TestClock()
        let environment = FakeImagingEnvironment()
        let launcher = FakeDdrescueLauncher()

        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: 512_000_000, total: Self.size, pass: 1)
                return nil
            },
            {
                writeMapfile(mapfile, rescued: 512_000_000, total: Self.size, pass: 1)
                return 0
            },
        ]
        let pass2 = FakeDdrescueProcess()
        // Ten minutes of a 200 B/s-style pass: rescued bytes do not move.
        pass2.ticks = (0..<12).map { _ in
            {
                writeMapfile(mapfile, rescued: 512_000_000, total: Self.size, pass: 2)
                return nil
            }
        }
        pass2.exitOnInterrupt = 130
        launcher.handles = [pass1, pass2]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: environment,
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination()),
            now: { clock.date },
            pollInterval: 120,
            sleep: { clock.date = clock.date.addingTimeInterval($0) }
        )

        #expect(result.exitCode == 1, "stopped by rule is incomplete and resumable")
        #expect(pass2.signals == [SIGINT], "the supervisor interrupts ddrescue gracefully")
        #expect(result.stdout.contains("stop rule"))
        #expect(result.stdout.contains("REMAINING"))
        #expect(result.stdout.contains("extents"))
        #expect(result.stdout.contains("RESUME"))
        #expect(result.stdout.contains("sudo disktriage image disk8"))
        #expect(result.stdout.contains("--no-dry-run"))
    }

    // MARK: - Device disappearance and errors

    @Test("REQ0081 a disappearing device gets SIGINT then SIGTERM and the mapfile state")
    func REQ0081_deviceDisappearanceInterruptsThenTerminates() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let environment = FakeImagingEnvironment()
        let launcher = FakeDdrescueLauncher()

        let pass1 = FakeDdrescueProcess()
        pass1.runsForeverWhenTicksEnd = true
        pass1.exitOnInterrupt = nil
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: 256_000_000, total: Self.size, pass: 1)
                environment.deviceExists = false
                return nil
            },
        ]
        launcher.handles = [pass1]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: environment,
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination()),
            pollInterval: 1,
            signalGrace: 0.2
        )

        #expect(result.exitCode == 1)
        #expect(pass1.signals == [SIGINT, SIGTERM], "graceful first, then terminate")
        #expect(result.stdout.contains("device disappeared"))
        #expect(result.stdout.contains("RESUME"))
        #expect(launcher.launches.count == 1, "pass 2 never starts without a device")
    }

    // REQ-0173: a ddrescue exit that is not ours is named with its code, and
    // the `-T` stop rule is spelled out instead of the generic "ddrescue
    // error" the real MiNaH run printed.
    @Test("REQ0173 a non-zero ddrescue exit shows its code, the -T rule, and keeps the mapfile")
    func REQ0173_stoppedOnItsOwnKeepsTheMapfile() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                // A `*` block: a read error was seen at 1024 and has not been
                // trimmed yet. The progress line must not hide it behind bad 0.
                try? """
                # Mapfile. Created by GNU ddrescue version 1.30
                # current_pos  current_status  current_pass
                0x00010400     ?               1
                #      pos        size  status
                0x00000000  0x00000400  +
                0x00000400  0x00010000  *
                0x00010400  0x3FFFFEFC00  ?

                """.write(toFile: mapfile, atomically: true, encoding: .utf8)
                return nil
            },
            { return 1 },
        ]
        launcher.handles = [pass1]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination())
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("ddrescue stopped on its own, exit 1"), "\(result.stdout)")
        #expect(result.stderr.contains("64.0 KiB (65536 bytes) failed (1 extents)"),
                "\(result.stderr)")
        #expect(!result.stdout.contains("ddrescue error"), "the stop reason is not a generic error")
        #expect(result.stderr.contains("pass 1 ddrescue stopped on its own, exit 1"), "\(result.stderr)")
        #expect(result.stdout.contains(
            "with -T 90 ddrescue stops after 90 s without a successful read"
        ), "\(result.stdout)")
        #expect(result.stdout.contains("the drive may be stalling on a bad region"))
        #expect(result.stdout.contains("the image is resumable"))
        #expect(FileManager.default.fileExists(atPath: mapfile), "the mapfile is evidence")
        #expect(launcher.launches.count == 1)
        #expect(result.stdout.contains("RESUME"))
        #expect(!result.stdout.contains("stop rule"), "the supervisor did not stop this pass")
    }

    @Test("REQ0173 ddrescue dying by SIGINT without our request is an interrupt, not an error")
    func REQ0173_ddrescueSIGINTIsInterrupted() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: 1024, total: Self.size, pass: 1)
                return 130
            },
        ]
        launcher.handles = [pass1]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination())
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("STOPPED   interrupted"))
        #expect(!result.stdout.contains("stopped on its own"))
    }

    // MARK: - Failed versus bad in the summary

    @Test("REQ0171 the image summary shows failed extents separately and never says only BAD 0")
    func REQ0171_summaryShowsFailedExtentsNotBadZero() throws {
        let text = try String(
            contentsOfFile: fixturePath("minah-partial-me.mapfile.txt"),
            encoding: .utf8
        )
        let snapshot = try #require(DdrescueMapfile.parse(text, limitBytes: 10_737_418_240))
        let summary = ImagingSummary(
            status: "incomplete",
            exitCode: 1,
            image: "/tmp/minah-test.img",
            mapfile: "/tmp/minah-test.img.mapfile",
            sidecar: "/tmp/minah-test.img.disktriage.json",
            rescuedBytes: snapshot.rescuedBytes,
            failedBytes: snapshot.failedBytes,
            failedExtents: snapshot.failedExtents.count,
            badBytes: snapshot.badBytes,
            badExtents: snapshot.badExtents.count,
            remainingBytes: snapshot.remainingBytes,
            remainingExtents: snapshot.remainingExtents.count,
            elapsedSeconds: 996.2,
            passReached: 1,
            stopped: .stoppedOnItsOwn,
            stopExitCode: 1,
            stopTimeout: "90",
            resumeCommand: "sudo disktriage image disk8 --no-dry-run",
            stop: nil,
            partialLimitBytes: 10_737_418_240,
            deviceBytes: 320_072_933_376
        )

        let rendered = renderImagingTTY(summary)
        #expect(rendered.contains(
            "RESCUED   3.2 GiB (3393650688 bytes)"
        ), "\(rendered)")
        #expect(rendered.contains(
            "FAILED    768.0 KiB (786432 bytes) in 12 extents "
                + "(read errors seen; not yet trimmed or scraped)"
        ), "\(rendered)")
        #expect(rendered.contains("BAD       0 bytes in 0 extents (confirmed)"), "\(rendered)")
        #expect(rendered.contains("STOPPED   ddrescue stopped on its own, exit 1"), "\(rendered)")
        #expect(!rendered.contains("\nBAD       0 bytes\n"), "a bare BAD 0 hides the failed extents")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(renderImagingJSON(summary).utf8))
                as? [String: Any]
        )
        #expect(object["failed_bytes"] as? Int == 786_432)
        #expect(object["failed_extents"] as? Int == 12)
        #expect(object["bad_bytes"] as? Int == 0)
        #expect(object["bad_extents"] as? Int == 0)
        #expect(object["stopped"] as? String == "ddrescue stopped on its own, exit 1")
        #expect(object["stop_exit_code"] as? Int == 1)
    }

    // MARK: - Refusals before the first read

    @Test("REQ0078 an existing image without a mapfile is never overwritten")
    func REQ0078_existingImageWithoutMapfileIsRefusedBeforeLaunch() {
        let launcher = FakeDdrescueLauncher()
        let facts = DestinationFacts(
            destinationExists: true,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
        let result = execute(
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: facts)
        )

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("mapfile"))
        #expect(result.stderr.contains("refusing"))
        #expect(launcher.launches.isEmpty)
    }

    // MARK: - Resume

    @Test("REQ0077 an interrupted run resumes from the mapfile and finishes")
    func REQ0077_resumeAfterInterrupt() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let environment = FakeImagingEnvironment()
        let clock = TestClock()
        let probe = DiskDestinationProbe()

        // First run: interrupted after the mapfile has a partial record.
        let firstLauncher = FakeDdrescueLauncher()
        let interrupted = FakeDdrescueProcess()
        interrupted.ticks = [
            {
                writeMapfile(mapfile, rescued: 256_000_000, total: Self.size, pass: 1)
                return nil
            },
        ]
        firstLauncher.handles = [interrupted]
        let flag = Box(false)

        let first = execute(
            image: image,
            mapfile: mapfile,
            environment: environment,
            launcher: firstLauncher,
            probe: probe,
            now: { clock.date },
            sleep: { _ in flag.value = true },
            interruptRequested: { flag.value }
        )

        #expect(first.exitCode == 1)
        #expect(first.stdout.contains("interrupted"))
        #expect(first.stdout.contains("RESUME"))
        #expect(interrupted.signals == [SIGINT])
        #expect(FileManager.default.fileExists(atPath: mapfile))
        #expect(FileManager.default.fileExists(atPath: image + ".disktriage.json"))

        // Second run: same command, same image, valid sidecar. ddrescue resumes
        // from the mapfile and both passes complete.
        let secondLauncher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: Self.size, total: Self.size, pass: 1, finished: true)
                return nil
            },
        ]
        secondLauncher.handles = [pass1, FakeDdrescueProcess()]
        let second = execute(
            image: image,
            mapfile: mapfile,
            environment: environment,
            launcher: secondLauncher,
            probe: probe,
            now: { clock.date }
        )

        #expect(second.exitCode == 0)
        #expect(second.stdout.contains("RESCUED"))
        #expect(second.stdout.contains("complete"))
        #expect(secondLauncher.launches.count == 2)
        #expect(secondLauncher.launches.filter { !$0.mapfileExisted }.isEmpty,
                "the second run starts from the mapfile")
        #expect(secondLauncher.launches.filter { !$0.sidecarExisted }.isEmpty)
    }

    // MARK: - Partial imaging

    // REQ-0105: the recorded limit is part of the resume authority. A partial
    // image is not resumed as a full one (or with another limit).
    @Test("REQ0105 resuming with a different limit or full versus partial exits 30")
    func REQ0105_resumingWithADifferentLimitIsRefused() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let limit: Int64 = 536_870_912 // 512 MiB, below the 1 GiB device

        FileManager.default.createFile(atPath: image, contents: Data())
        try "# Mapfile. Created by GNU ddrescue version 1.30\n"
            .write(toFile: mapfile, atomically: true, encoding: .utf8)
        let sidecar = ImageSidecar(
            schema: "disktriage.image/1",
            device: ImageSidecarDevice(
                model: "Synthetic Bridge Disk",
                serialSHA256: Self.serialHash,
                sizeBytes: Self.size
            ),
            createdAt: "2026-11-07T01:00:00Z",
            command: ["caffeinate -dimsu ddrescue -n -s \(limit) /dev/rdisk8"],
            limitBytes: limit
        )
        try JSONEncoder().encode(sidecar).write(
            to: URL(fileURLWithPath: image + ".disktriage.json")
        )

        // The same image and mapfile, requested as a full image now.
        let refusedLauncher = FakeDdrescueLauncher()
        let refused = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: refusedLauncher,
            probe: DiskDestinationProbe()
        )
        #expect(refused.exitCode == 30, "a limit-state mismatch is a precondition error")
        #expect(refused.stderr.contains("limit"), "the refusal names the limit")
        #expect(refused.stderr.contains("partial"), "the refusal names the partial image")
        #expect(refusedLauncher.launches.isEmpty, "nothing is read before the refusal")

        // The same limit still resumes.
        let launcher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            { writeMapfile(mapfile, rescued: limit, total: limit, pass: 1, finished: true); return 0 },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = [
            { writeMapfile(mapfile, rescued: limit, total: limit, pass: 2, finished: true); return 0 },
        ]
        launcher.handles = [pass1, pass2]
        let resumed = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: DiskDestinationProbe(),
            limitBytes: limit
        )
        #expect(resumed.exitCode == 0, "the same limit is a valid resume")
        #expect(launcher.launches.count == 2)
    }

    // REQ-0106: a partial run that finished is a partial image, never a
    // complete image of the device, in both renderings.
    @Test("REQ0106 a partial run is never reported as a complete image of the device")
    func REQ0106_partialCompleteIsNeverCalledComplete() throws {
        let limit: Int64 = 8 * 1_048_576 // 8 MiB, injected at the byte seam

        func runPartial(asJSON: Bool) throws -> CLIResult {
            let directory = try temporaryDirectory()
            let image = directory + "/disk8.img"
            let mapfile = image + ".mapfile"
            let launcher = FakeDdrescueLauncher()
            let pass1 = FakeDdrescueProcess()
            pass1.ticks = [
                { writeMapfile(mapfile, rescued: limit, total: limit, pass: 1, finished: true); return 0 },
            ]
            let pass2 = FakeDdrescueProcess()
            pass2.ticks = [
                { writeMapfile(mapfile, rescued: limit, total: limit, pass: 2, finished: true); return 0 },
            ]
            launcher.handles = [pass1, pass2]
            return execute(
                image: image,
                mapfile: mapfile,
                environment: FakeImagingEnvironment(),
                launcher: launcher,
                probe: FakeImageProbe(facts: emptyDestination()),
                extra: asJSON ? ["--json"] : [],
                limitBytes: limit
            )
        }

        let text = try runPartial(asJSON: false)
        #expect(text.exitCode == 0, "hitting the limit with both passes is exit 0")
        #expect(text.stdout.contains("partial image complete (first 8388608 bytes)"))
        #expect(text.stdout.contains("STOPPED   partial image complete (first 8388608 bytes)"),
                "the outcome wording is partial, not complete")
        #expect(!text.stdout.contains("complete image of the device"))
        #expect(text.stdout.contains("RESUME") == false)

        let json = try runPartial(asJSON: true)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        )
        #expect(object["status"] as? String == "partial image complete (first 8388608 bytes)")
        #expect(object["stopped"] as? String == "partial image complete (first 8388608 bytes)")
        #expect(object["partial"] as? Bool == true)
        #expect((object["limit_bytes"] as? Int64) == limit || (object["limit_bytes"] as? Int) == Int(limit))
        #expect(object["exit_code"] as? Int == 0)
        #expect(object["resume_command"] == nil)
    }

    // REQ-0107: the stop rule's threshold and remaining bytes are computed from
    // the limited image size. With a 1 GiB device but an 8 MiB limit, a 2,000 B
    // yield in the window is above 0.01% of 8 MiB, so the rule must not fire;
    // computing against the 1 GiB device would stop the run.
    @Test("REQ0107 the pass-2 stop rule uses the limited image size")
    func REQ0107_stopRuleUsesTheLimitedImageSize() throws {
        let limit: Int64 = 8 * 1_048_576
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let clock = TestClock()
        let launcher = FakeDdrescueLauncher()

        // Pass 1 leaves 200,000 B unread; pass 2 rescues 1,000 B per two-minute
        // tick, so every ten-minute window yields 5,000–6,000 B. That is well
        // above 0.01% of the 8 MiB limit (838.86 B) but well below 0.01% of the
        // 1 GiB device (107,374 B): only the limited-size math keeps going.
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            { writeMapfile(mapfile, rescued: limit - 200_000, total: limit, pass: 1, finished: true); return 0 },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = (0..<12).map { index in
            {
                writeMapfile(
                    mapfile,
                    rescued: limit - 200_000 + Int64(index + 1) * 1_000,
                    total: limit,
                    pass: 2
                )
                return nil
            }
        }
        pass2.exitOnInterrupt = 130
        launcher.handles = [pass1, pass2]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination()),
            now: { clock.date },
            pollInterval: 120,
            sleep: { clock.date = clock.date.addingTimeInterval($0) },
            limitBytes: limit
        )

        #expect(result.exitCode == 0, "the limited-size threshold is not met")
        #expect(pass2.signals.isEmpty, "the stop rule must not interrupt this run")
    }

    // REQ-0108: the live summary and progress use the same clamped accounting
    // as the parser: rescued/bad/remaining/extents/percent are inside the limit.
    // The device fixture is 1 GiB, so the partial limit is 512 MiB and
    // ddrescue's untried tail still runs to Int64.max.
    @Test("REQ0108 a partial run reports rescued, remaining, extents and percent inside the limit")
    func REQ0108_partialSummaryAndProgressStayInsideTheLimit() throws {
        let limit: Int64 = 536_870_912 // 512 MiB of a 1 GiB device
        let rescued: Int64 = 268_435_456 // 256 MiB

        func runPartial(asJSON: Bool) throws -> CLIResult {
            let directory = try temporaryDirectory()
            let image = directory + "/disk8.img"
            let mapfile = image + ".mapfile"
            let launcher = FakeDdrescueLauncher()
            let flag = Box(false)
            let pass1 = FakeDdrescueProcess()
            pass1.ticks = [
                {
                    writeMapfile(mapfile, rescued: rescued, total: Int64.max, pass: 1)
                    flag.value = true
                    return nil
                },
            ]
            pass1.exitOnInterrupt = 130
            launcher.handles = [pass1]
            return execute(
                image: image,
                mapfile: mapfile,
                environment: FakeImagingEnvironment(),
                launcher: launcher,
                probe: FakeImageProbe(facts: emptyDestination()),
                extra: asJSON ? ["--json"] : [],
                interruptRequested: { flag.value },
                limitBytes: limit
            )
        }

        let text = try runPartial(asJSON: false)
        #expect(text.exitCode == 1, "the interrupted run is incomplete and resumable")
        #expect(text.stdout.contains("256.0 MiB (268435456 bytes) in 1 extents"),
                "remaining is 512 MiB - 256 MiB rescued, not Int64.max - rescued")
        #expect(!text.stdout.contains("922337203"), "the unbounded tail is not printed")
        #expect(text.stderr.contains("50.0% rescued"),
                "the percentage is of the limit, not of the tail")
        #expect(!text.stderr.contains("GiB"), "progress remaining is inside the limit")

        let json = try runPartial(asJSON: true)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        )
        #expect((object["rescued_bytes"] as? Int64) == rescued
            || (object["rescued_bytes"] as? Int) == Int(rescued))
        #expect((object["remaining_bytes"] as? Int64) == 268_435_456
            || (object["remaining_bytes"] as? Int) == 268_435_456)
        #expect(object["remaining_extents"] as? Int == 1)
        #expect(object["status"] as? String == "incomplete")
        #expect(object["stopped"] as? String == "interrupted")
    }

    // REQ-0109: completion is ddrescue's exit code, never the mapfile tail. A
    // pass that exits 0 starts pass 2 even though an untried tail exists past
    // the limit; if the decision read the unclamped extent, pass 2 would not run.
    @Test("REQ0109 a partial pass exiting 0 is complete without reading the huge tail")
    func REQ0109_partialCompletionUsesDdrescueExitNotTheUnclampedTail() throws {
        let limit: Int64 = 536_870_912 // 512 MiB of a 1 GiB device
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()

        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: limit, total: Int64.max, pass: 1, finished: true)
                return nil
            },
            { return 0 },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = [
            {
                writeMapfile(mapfile, rescued: limit, total: Int64.max, pass: 2, finished: true)
                return nil
            },
            { return 0 },
        ]
        launcher.handles = [pass1, pass2]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination()),
            limitBytes: limit
        )

        #expect(result.exitCode == 0)
        #expect(launcher.launches.count == 2,
                "pass 1 exited 0, so pass 2 runs; the unbounded tail is not consulted")
        #expect(result.stdout.contains("partial image complete (first 536870912 bytes)"))
        #expect(result.stdout.contains("0 bytes in 0 extents"),
                "nothing remains to try inside the limit")
    }

    // REQ-0110: the stop rule's projection uses the remaining bytes inside the
    // limit. A 500 B yield over the window keeps the run going because only a
    // few hundred bytes remain; reading the Int64.max tail would project
    // centuries and stop it.
    @Test("REQ0110 the pass-2 stop rule measures remaining inside the limit")
    func REQ0110_stopRuleUsesClampedRemaining() throws {
        let limit: Int64 = 536_870_912 // 512 MiB of a 1 GiB device
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let clock = TestClock()
        let launcher = FakeDdrescueLauncher()

        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: limit - 1_200, total: Int64.max, pass: 1, finished: true)
                return 0
            },
        ]
        let pass2 = FakeDdrescueProcess()
        pass2.ticks = (0..<12).map { index in
            {
                writeMapfile(
                    mapfile,
                    rescued: limit - 1_200 + Int64(index + 1) * 100,
                    total: Int64.max,
                    pass: 2
                )
                return nil
            }
        }
        pass2.exitOnInterrupt = 130
        launcher.handles = [pass1, pass2]

        let result = execute(
            image: image,
            mapfile: mapfile,
            environment: FakeImagingEnvironment(),
            launcher: launcher,
            probe: FakeImageProbe(facts: emptyDestination()),
            now: { clock.date },
            pollInterval: 120,
            sleep: { clock.date = clock.date.addingTimeInterval($0) },
            limitBytes: limit
        )

        #expect(pass2.signals.isEmpty,
                "the projection is 100s of bytes, not the Int64.max tail")
        #expect(result.exitCode == 0, "the run finishes normally")
    }

    // MARK: - Helpers

    private func execute(
        image: String? = nil,
        mapfile: String? = nil,
        environment: FakeImagingEnvironment,
        launcher: FakeDdrescueLauncher,
        probe: (any ImageDestinationProbing)? = nil,
        extra: [String] = [],
        now: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 0.01,
        signalGrace: TimeInterval = 0.2,
        sleep: @escaping (TimeInterval) -> Void = { _ in },
        interruptRequested: @escaping () -> Bool = { false },
        limitBytes: Int64? = nil
    ) -> CLIResult {
        let destination = image ?? "/tmp/disktriage-test-\(UUID().uuidString).img"
        let destinationProbe = probe ?? FakeImageProbe(facts: emptyDestination())
        let map = mapfile ?? destination + ".mapfile"
        let dependencies = ImagingDependencies(
            environment: environment,
            launcher: launcher,
            pollInterval: pollInterval,
            signalGrace: signalGrace,
            sleep: sleep,
            readMapfile: { path in try? String(contentsOfFile: path, encoding: .utf8) },
            interruptRequested: interruptRequested
        )
        return DiskTriageCLI.image(
            [
                "disk8", "--to", destination, "--no-dry-run",
                "--accept-risk", "--confirm-serial", "ABCD",
            ] + extra,
            executor: scriptedExecutor(),
            now: now,
            destinationProbe: destinationProbe,
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: dependencies,
            limitBytesOverride: limitBytes
        )
    }

    private func emptyDestination() -> DestinationFacts {
        DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
    }
}

// MARK: - Seams

final class FakeImagingEnvironment: ImagingEnvironmentProbing, @unchecked Sendable {
    var root = true
    var fda = FDAStatus(
        state: .granted,
        evidence: .read(bytes: 4096),
        needsSudo: false,
        tccPassed: true,
        detail: "read 4096 bytes"
    )
    var guardValue: GuardState = .daemonStopped
    var ddrescue = true
    var terminalIdentity = TerminalIdentity(name: "Ghostty", bundlePath: "/Applications/Ghostty.app")
    var deviceExists = true
    var probeCount = 0

    func isRoot() -> Bool { probeCount += 1; return root }
    func fdaStatus() -> FDAStatus { fda }
    func guardState() -> GuardState { guardValue }
    func ddrescueAvailable() -> Bool { ddrescue }
    func terminal() -> TerminalIdentity { terminalIdentity }
    func deviceExists(_ path: String) -> Bool { deviceExists }
}

final class FakeDdrescueLauncher: DdrescueLaunching, @unchecked Sendable {
    struct Launch {
        let argv: [String]
        let mapfile: String
        let mapfileExisted: Bool
        let sidecarExisted: Bool
    }

    var launches: [Launch] = []
    var handles: [FakeDdrescueProcess] = []

    func launch(argv: [String]) throws -> any DdrescueProcessHandle {
        let mapfile = argv.last ?? ""
        let image = argv.count >= 2 ? argv[argv.count - 2] : ""
        let manager = FileManager.default
        if !manager.fileExists(atPath: image) {
            manager.createFile(atPath: image, contents: Data())
        }
        launches.append(Launch(
            argv: argv,
            mapfile: mapfile,
            mapfileExisted: manager.fileExists(atPath: mapfile),
            sidecarExisted: manager.fileExists(atPath: image + ".disktriage.json")
        ))
        if !handles.isEmpty {
            return handles.removeFirst()
        }
        return FakeDdrescueProcess()
    }
}

final class FakeDdrescueProcess: DdrescueProcessHandle, @unchecked Sendable {
    let pid: Int32 = 4242
    var ticks: [() -> Int32?] = []
    private var index = 0
    private var exitCode: Int32?
    var signals: [Int32] = []
    var exitOnInterrupt: Int32? = 130
    var exitOnTerminate: Int32? = 143
    var runsForeverWhenTicksEnd = false

    func poll() -> Int32? {
        if let exitCode { return exitCode }
        if index < ticks.count {
            let tick = ticks[index]
            index += 1
            if let code = tick() {
                exitCode = code
                return code
            }
            return nil
        }
        if runsForeverWhenTicksEnd { return nil }
        exitCode = 0
        return 0
    }

    func signal(_ signal: Int32) {
        signals.append(signal)
        if signal == SIGINT, let code = exitOnInterrupt { exitCode = code }
        if signal == SIGTERM, let code = exitOnTerminate { exitCode = code }
    }
}

/// Reads the real image/mapfile/sidecar from a temp directory, so the resume
/// test exercises the same validation the shipped probe does.
struct DiskDestinationProbe: ImageDestinationProbing {
    func probe(destination: String, mapfile: String) -> DestinationFacts {
        let manager = FileManager.default
        let imageExists = manager.fileExists(atPath: destination)
        let mapfileExists = manager.fileExists(atPath: mapfile)
        var sidecar: ImageSidecar?
        var sidecarError: String?
        if imageExists {
            let path = destination + ".disktriage.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                do {
                    sidecar = try JSONDecoder().decode(ImageSidecar.self, from: data)
                } catch {
                    sidecarError = error.localizedDescription
                }
            }
        }
        return DestinationFacts(
            destinationExists: imageExists,
            mapfileExists: mapfileExists,
            sidecar: sidecar,
            sidecarError: sidecarError,
            freeBytes: 2_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: "disk0"
        )
    }
}

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Fixtures

func temporaryDirectory() throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("disktriage-tests-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func writeMapfile(
    _ path: String,
    rescued: Int64,
    total: Int64,
    pass: Int = 1,
    finished: Bool = false
) {
    let remaining = max(0, total - rescued)
    var rows = [
        String(format: "0x%016llX  0x%016llX  +", 0, rescued),
    ]
    if remaining > 0 {
        rows.append(String(format: "0x%016llX  0x%016llX  ?", rescued, remaining))
    }
    let text = """
    # Mapfile. Created by GNU ddrescue version 1.30
    # Command line: ddrescue fake
    # Start time:   2026-11-07 01:00:00
    # Current time: 2026-11-07 01:10:00
    \(finished ? "# Finished" : "")
    # current_pos  current_status  current_pass
    0x00000000     +               \(pass)
    #      pos        size  status
    \(rows.joined(separator: "\n"))

    """
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

func decodeSidecar(_ path: String) throws -> ImageSidecar {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(ImageSidecar.self, from: data)
}

func scriptedExecutor() -> CLIExecutor {
    CLIExecutor { command in
        switch command {
        case .diskutilInfo:
            return .ok(executionFixtureText("diskutil-info-usb-synthetic-serial.plist"))
        case .ioregStatistics:
            return .ok(executionFixtureText("ioreg-internal-driver.txt"))
        case .ioregMedia:
            return .ok(executionFixtureText("ioreg-iomedia-internal.txt"))
        case .logShow:
            return .ok(executionFixtureText("kernel-log-healthy-compact.txt"))
        case .smartctl:
            return .ok(#"{"smartctl":{"exit_status":0}}"#)
        default:
            return .ok("")
        }
    }
}

private func executionFixtureText(_ name: String) -> String {
    (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
}
