import Foundation
import Testing
@testable import DiskTriageCLI
import DiskTriageCollectors

/// `image` and `triage` through the identity path that never waits on a hung
/// `diskutil`: a stopped DiskArbitration daemon, and a plain timeout.
struct ImageIORegFallbackTests {

    private func facts(backing: String = "disk0") -> DestinationFacts {
        DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 6_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisk: backing
        )
    }

    /// A runner whose `diskutil` hangs/times out and whose ioreg trees are the
    /// recorded fixtures. Every other collector gets a harmless empty answer.
    private func timeoutThenIOReg(_ fixture: String) -> CLIExecutor {
        CLIExecutor { command in
            switch command {
            case .pgrepDiskArbitrationDaemon:
                return .ok("")
            case .diskutilInfo:
                return CollectorResult(outcome: .timeout, durationMs: 30_000)
            case .ioregDeviceTree:
                return .ok(fixtureText(fixture))
            case .ioregStatistics:
                return .ok(fixtureText("ioreg-internal-driver.txt"))
            case .ioregMedia:
                return .ok(fixtureText("ioreg-iomedia-internal.txt"))
            case .logShow:
                return .ok("")
            case .smartctl:
                return .ok(#"{"smartctl":{"exit_status":0}}"#)
            default:
                return .ok("")
            }
        }
    }

    /// DiskArbitration is stopped: diskutil would hang.
    private func stoppedDA(_ fixture: String) -> CLIExecutor {
        CLIExecutor { command in
            switch command {
            case .pgrepDiskArbitrationDaemon:
                return .ok("155\n")
            case .processState(pid: 155):
                return .ok("T\n")
            case .ioregDeviceTree:
                return .ok(fixtureText(fixture))
            case .ioregStatistics:
                return .ok(fixtureText("ioreg-internal-driver.txt"))
            case .ioregMedia:
                return .ok(fixtureText("ioreg-iomedia-internal.txt"))
            case .logShow:
                return .ok("")
            case .smartctl:
                return .ok(#"{"smartctl":{"exit_status":0}}"#)
            case .diskutilInfo:
                return .ok("diskutil must not run while it would hang")
            default:
                return .ok("")
            }
        }
    }

    // REQ-0162 / REQ-0164: a timed-out diskutil no longer makes image exit 30.
    @Test("REQ0162_REQ0164 image dry-run reads identity from ioreg after a diskutil timeout")
    func REQ0162_REQ0164_imageDryRunFallsBackAfterTimeout() {
        let executor = timeoutThenIOReg("ioreg-device-usb-with-serial.txt")
        let result = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-serial", "ABCD"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )

        #expect(result.exitCode == 0, "the identity path worked: \(result.stderr)")
        #expect(result.stdout.contains("MODEL") && result.stdout.contains("SSD 850 EVO"))
        #expect(result.stdout.contains("SERIAL") && result.stdout.contains("DEMO-USB-0000ABCD"))
        #expect(result.stdout.contains("BUS") && result.stdout.contains("usb"))
        #expect(!result.stderr.contains("cannot read the identity"))
        #expect(executor.commands.contains { if case .ioregDeviceTree = $0 { return true }; return false })
        #expect(executor.commands.contains { if case .diskutilInfo = $0 { return true }; return false },
                "the timeout really happened before the fallback")
    }

    // REQ-0163: the serial from ioreg is the confirmation; when it is absent
    // the size is, and neither is skipped.
    @Test("REQ0163 ioreg serial confirmation uses the last four characters")
    func REQ0163_serialConfirmationFromIOReg() {
        let executor = timeoutThenIOReg("ioreg-device-usb-with-serial.txt")

        let missing = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )
        #expect(missing.exitCode == 2)
        #expect(missing.stdout.contains("--confirm-serial ABCD"))

        let right = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-serial", "ABCD"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )
        #expect(right.exitCode == 0)
    }

    @Test("REQ0163 an unexposed ioreg serial falls back to --confirm-size")
    func REQ0163_sizeConfirmationFromIOReg() {
        let executor = timeoutThenIOReg("ioreg-device-usb-hdd-no-serial.txt")

        let missing = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )
        #expect(missing.exitCode == 2)
        #expect(missing.stdout.contains("--confirm-size 4657"),
                "5,000,981,077,504 B is 4657 GiB truncated")
        #expect(missing.stdout.contains("unreadable (confirm by size)"))

        let wrong = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-size", "4656"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )
        #expect(wrong.exitCode == 2)

        let right = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-size", "4657"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )
        #expect(right.exitCode == 0)
    }

    // REQ-0161 at the command seam: with the daemon stopped, image succeeds
    // and the spy sees no diskutil invocation.
    @Test("REQ0161 image never invokes diskutil while DiskArbitration is stopped")
    func REQ0161_imageNeverInvokesDiskutilWhenStopped() {
        let executor = stoppedDA("ioreg-device-usb-with-serial.txt")
        let result = run(
            arguments: ["image", "disk8", "--to", "/tmp/x.img", "--confirm-serial", "ABCD"],
            executor: executor,
            destinationProbe: FakeImageProbe(facts: facts())
        )

        #expect(result.exitCode == 0, "the safety features are not mutually exclusive: \(result.stderr)")
        #expect(!executor.commands.contains { command in
            if case .diskutilInfo = command { return true }
            return false
        }, "a spy proves diskutil was never called")
        #expect(executor.commands.contains { if case .ioregDeviceTree = $0 { return true }; return false })
    }

    // REQ-0162 at the triage seam: the live identity comes from ioreg.
    @Test("REQ0162 triage reports an ioreg identity while DiskArbitration is stopped")
    func REQ0162_triageReadsIdentityFromIOReg() {
        let executor = stoppedDA("ioreg-device-usb-with-serial.txt")
        let result = run(
            arguments: ["triage", "disk8", "--no-history"],
            executor: executor
        )

        #expect(result.exitCode != 30, "identity collection did not fail the run: \(result.stderr)")
        #expect(result.stdout.contains("MODEL"))
        #expect(result.stdout.contains("SSD 850 EVO"))
        #expect(result.stdout.contains("SERIAL"))
        #expect(result.stdout.contains("DEMO-USB-0000ABCD"))
        #expect(!executor.commands.contains { command in
            if case .diskutilInfo = command { return true }
            return false
        })
    }
}

private func fixtureText(_ name: String) -> String {
    (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
}
