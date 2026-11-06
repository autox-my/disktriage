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
            blockSize: 512
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

    @Test("a non-zero ddrescue exit is reported, the mapfile is kept, and pass 2 does not start")
    func ddrescueErrorKeepsTheMapfile() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let launcher = FakeDdrescueLauncher()
        let pass1 = FakeDdrescueProcess()
        pass1.ticks = [
            {
                writeMapfile(mapfile, rescued: 1024, total: Self.size, pass: 1)
                return 1
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
        #expect(result.stdout.contains("ddrescue error"))
        #expect(FileManager.default.fileExists(atPath: mapfile), "the mapfile is evidence")
        #expect(launcher.launches.count == 1)
        #expect(result.stdout.contains("RESUME"))
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
        interruptRequested: @escaping () -> Bool = { false }
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
        return run(
            arguments: [
                "image", "disk8", "--to", destination, "--no-dry-run",
                "--accept-risk", "--confirm-serial", "ABCD",
            ] + extra,
            executor: scriptedExecutor(),
            now: now,
            destinationProbe: destinationProbe,
            imaging: dependencies
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
