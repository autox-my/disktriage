import Foundation
import Darwin
import Testing
@testable import DiskTriageCLI
@testable import DiskTriageCollectors
import DiskTriageCore

/// The destination walk and the whole `image --no-dry-run` path with
/// DiskArbitration stopped: `diskutil` is never allowed to hang the run.
struct ImageStoppedDaEndToEndTests {

    private func fixture(_ name: String) -> String {
        (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
    }

    // MARK: - The pure walk at the probe seam

    // REQ-0166: a stopped daemon resolves the destination through ioreg only.
    @Test("REQ0166 stopped DiskArbitration resolves the destination through ioreg")
    func REQ0166_stoppedDestinationUsesIOReg() {
        let executor = CLIExecutor { command in
            switch command {
            case .ioregMediaTree:
                return .ok(self.fixture("ioreg-iomedia-tree-internal-apfs.txt"))
            case .diskutilInfo:
                return .timeout()
            default:
                return .ok("")
            }
        }

        let result = SystemImageDestinationProbe.resolveBackingDisks(
            mountSource: "/dev/disk3s5",
            executor: executor,
            diskutilSkipReason: DiskArbitrationProbe.stoppedReason
        )

        #expect(result.disks == ["disk0"], "the internal NVMe behind the APFS container")
        #expect(result.source == "ioreg")
        #expect(result.error == nil)
        #expect(!executor.commands.contains { if case .diskutilInfo = $0 { return true }; return false })
    }

    @Test("REQ0166 a plain USB volume resolves to its whole disk through ioreg")
    func REQ0166_plainVolumeThroughIOReg() {
        let executor = CLIExecutor { command in
            switch command {
            case .ioregMediaTree:
                return .ok(self.fixture("ioreg-iomedia-tree-usb.txt"))
            default:
                return .ok("")
            }
        }

        let result = SystemImageDestinationProbe.resolveBackingDisks(
            mountSource: "/dev/disk8s2",
            executor: executor,
            diskutilSkipReason: DiskArbitrationProbe.stoppedReason
        )

        #expect(result.disks == ["disk8"])
        #expect(result.source == "ioreg")
    }

    // REQ-0170: a mount source that is not a local disk is unverifiable, not a
    // pass and not a silent disk0.
    @Test("REQ0170 a network mount is unverifiable through both paths")
    func REQ0170_networkMountIsUnverifiable() {
        let executor = CLIExecutor { _ in .ok(self.fixture("ioreg-iomedia-tree-internal-apfs.txt")) }

        let stopped = SystemImageDestinationProbe.resolveBackingDisks(
            mountSource: "//server/share",
            executor: executor,
            diskutilSkipReason: DiskArbitrationProbe.stoppedReason
        )
        let running = SystemImageDestinationProbe.resolveBackingDisks(
            mountSource: "//server/share",
            executor: CLIExecutor { _ in .ok("") },
            diskutilSkipReason: nil
        )

        #expect(stopped.disks.isEmpty)
        #expect(stopped.error != nil)
        #expect(running.disks.isEmpty)
        #expect(running.error?.contains("local whole disk") == true)
    }

    // The running-daemon path is today's behaviour: diskutil first.
    @Test("REQ0169 a running daemon resolves the destination with diskutil first")
    func REQ0169_runningDaKeepsDiskutilWalk() {
        let executor = CLIExecutor { command in
            switch command {
            case .diskutilInfo(let disk):
                return disk == "disk0"
                    ? .ok(self.fixture("diskutil-info-internal.plist"))
                    : .ok(self.fixture("diskutil-info-virtual-apfs.plist"))
            default:
                return .ok("")
            }
        }

        let result = SystemImageDestinationProbe.resolveBackingDisks(
            mountSource: "/dev/disk3s5",
            executor: executor,
            diskutilSkipReason: nil
        )

        #expect(result.disks == ["disk0"])
        #expect(result.source == "diskutil")
        #expect(executor.commands.contains(.diskutilInfo(disk: "disk3")),
                "the synthesized container was walked")
    }

    // REQ-0166: a diskutil timeout is evidence, and the ioreg fallback is
    // taken once rather than waiting again.
    @Test("REQ0166 a diskutil timeout falls back to ioreg for the destination")
    func REQ0166_destinationTimeoutFallsBack() {
        let executor = CLIExecutor { command in
            switch command {
            case .diskutilInfo:
                return .timeout()
            case .ioregMediaTree:
                return .ok(self.fixture("ioreg-iomedia-tree-internal-apfs.txt"))
            default:
                return .ok("")
            }
        }

        let result = SystemImageDestinationProbe.resolveBackingDisks(
            mountSource: "/dev/disk3s5",
            executor: executor,
            diskutilSkipReason: nil
        )

        #expect(result.disks == ["disk0"])
        #expect(result.source == "ioreg")
    }

    // REQ-0170: an unresolved backing disk is UNVERIFIABLE, never a pass.
    @Test("REQ0170 an unresolved backing disk fails the destination check closed")
    func REQ0170_unresolvedBackingFailsClosed() {
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 6_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingError: "ioreg has no IOMedia for disk3"
        )

        let checks = assessDestination(
            facts: facts,
            source: ImageSource(bsd: "disk8", sizeBytes: 1_073_741_824)
        )
        let sourceCheck = checks.first { $0.name == "not on the source disk" }
        #expect(sourceCheck?.outcome == .unknown, "unknown is not a pass")
        #expect(sourceCheck?.detail.contains("ioreg has no IOMedia") == true)
    }

    // REQ-0167: the source comparison uses the whole disk of the source, and a
    // store equal to it refuses the destination.
    @Test("REQ0167 a multi-store backing that contains the source is refused")
    func REQ0167_multiStoreSourceComparison() {
        let facts = DestinationFacts(
            destinationExists: false,
            mapfileExists: false,
            freeBytes: 6_000_000_000_000,
            containerFilesystem: "apfs",
            parentIsWritable: true,
            backingWholeDisks: ["disk0", "disk8"]
        )
        let checks = assessDestination(
            facts: facts,
            source: ImageSource(bsd: "disk8", sizeBytes: 1_073_741_824)
        )
        let sourceCheck = checks.first { $0.name == "not on the source disk" }
        #expect(sourceCheck?.outcome == .refuse)
        #expect(sourceCheck?.detail.contains("disk8") == true)
    }

    // MARK: - End to end

    // REQ-0169: the whole image flow completes with diskutil never invoked,
    // including the FDA precondition, identity, triage and destination walk.
    @Test("REQ0169 image --no-dry-run completes with zero diskutil calls while stopped")
    func REQ0169_fullImageNeverCallsDiskutil() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let executor = stoppedExecutor(destinationPath: directory)
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
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            destinationProbe: nil,
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: ImagingDependencies(
                environment: FakeImagingEnvironment(),
                launcher: launcher
            )
        )

        #expect(result.exitCode == 0, "the image completed: \(result.stderr)")
        #expect(result.stdout.contains("complete"))
        #expect(executor.diskutilCalls == 0, "no diskutil call at all, not even a timeout")
        #expect(executor.commands.contains(.ioregMediaTree), "the destination used ioreg")
        #expect(FileManager.default.fileExists(atPath: image), "the image")
        #expect(FileManager.default.fileExists(atPath: mapfile), "the mapfile")
        #expect(FileManager.default.fileExists(atPath: image + ".disktriage.json"), "the sidecar")
        #expect(launcher.launches.count == 2)
    }

    // The same flow with a running daemon keeps today's diskutil-first path.
    @Test("REQ0169 a running daemon keeps the diskutil-first image flow")
    func REQ0169_runningDaKeepsDiskutilFirst() throws {
        let directory = try temporaryDirectory()
        let image = directory + "/disk8.img"
        let mapfile = image + ".mapfile"
        let executor = runningExecutor()
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
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            destinationProbe: nil,
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path)) },
            imaging: ImagingDependencies(
                environment: FakeImagingEnvironment(),
                launcher: launcher
            )
        )

        #expect(result.exitCode == 0, "the image completed: \(result.stderr)")
        #expect(executor.diskutilCalls > 0, "today's behaviour is unchanged")
        #expect(executor.commands.contains(.diskutilInfo(disk: "disk8")), "identity from diskutil")
        #expect(!executor.commands.contains(.ioregMediaTree), "the destination did not need ioreg")
    }
}

// MARK: - Scripted runners

private func stoppedExecutor(destinationPath: String) -> CLIExecutor {
    let tree = destinationTree(for: destinationPath)
    return CLIExecutor { command in
        switch command {
        case .pgrepDiskArbitrationDaemon:
            return .ok("155\n")
        case .processState(pid: 155):
            return .ok("T\n")
        case .ioregDeviceTree:
            return .ok(cliFixture("ioreg-device-usb-with-serial.txt"))
        case .ioregMediaTree:
            return .ok(tree)
        case .ioregStatistics:
            return .ok(cliFixture("ioreg-internal-driver.txt"))
        case .ioregMedia:
            return .ok(cliFixture("ioreg-iomedia-internal.txt"))
        case .logShow:
            return .ok("")
        case .smartctl:
            return .ok(#"{"smartctl":{"exit_status":0}}"#)
        case .diskutilList, .diskutilListFilesystems:
            return .timeout()
        case .diskutilInfo:
            return .timeout()
        default:
            return .ok("")
        }
    }
}

private func runningExecutor() -> CLIExecutor {
    CLIExecutor { command in
        switch command {
        case .pgrepDiskArbitrationDaemon:
            return .ok("155\n")
        case .processState(pid: 155):
            return .ok("Ss\n")
        case .diskutilInfo(let disk):
            switch disk {
            case "disk8":
                return .ok(cliFixture("diskutil-info-usb-synthetic-serial.plist"))
            case "disk0":
                return .ok(cliFixture("diskutil-info-internal.plist"))
            default:
                return .ok(cliFixture("diskutil-info-virtual-apfs.plist"))
            }
        case .ioregStatistics:
            return .ok(cliFixture("ioreg-internal-driver.txt"))
        case .ioregMedia:
            return .ok(cliFixture("ioreg-iomedia-internal.txt"))
        case .logShow:
            return .ok("")
        case .smartctl:
            return .ok(#"{"smartctl":{"exit_status":0}}"#)
        default:
            return .ok("")
        }
    }
}

/// The recorded APFS tree for this Mac, or a minimal equivalent for a host
/// whose temp directory is mounted from another whole disk.
private func destinationTree(for path: String) -> String {
    var stats = statfs()
    let source: String = path.withCString { pointer in
        guard statfs(pointer, &stats) == 0 else { return "/dev/disk3s5" }
        return withUnsafePointer(to: &stats.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1024) {
                String(cString: $0)
            }
        }
    }
    if source == "/dev/disk3s5" {
        return cliFixture("ioreg-iomedia-tree-internal-apfs.txt")
    }

    let whole = MountedDeviceSource.wholeDiskName(fromMountSource: source) ?? "disk99"
    let slice = (source as NSString).lastPathComponent
    if whole == "disk0" {
        return """
        +-o Internal Media  <class IOMedia, id 0x1, registered, matched, active, busy 0, retain 1>
          | {
          |   "Whole" = Yes
          |   "BSD Name" = "disk0"
          |   "Size" = 1000000000000
          | }
          |
          +-o Volume  <class IOMedia, id 0x2, registered, matched, active, busy 0, retain 1>
            | {
            |   "Whole" = No
            |   "BSD Name" = "\(slice)"
            | }
        """
    }
    return """
    +-o Internal Media  <class IOMedia, id 0x1, registered, matched, active, busy 0, retain 1>
      | {
      |   "Whole" = Yes
      |   "BSD Name" = "disk0"
      |   "Size" = 1000000000000
      | }
      |
      +-o Container  <class IOMedia, id 0x2, registered, matched, active, busy 0, retain 1>
        | {
        |   "Whole" = No
        |   "BSD Name" = "disk0s2"
        |   "UUID" = "00000000-0000-0000-0000-000000000001"
        | }
        |
        +-o AppleAPFSContainerScheme  <class AppleAPFSContainerScheme, id 0x3, registered, matched, active, busy 0, retain 1>
          +-o AppleAPFSMedia  <class AppleAPFSMedia, id 0x4, registered, matched, active, busy 0, retain 1>
            | {
            |   "Whole" = Yes
            |   "BSD Name" = "\(whole)"
            |   "UUID" = "00000000-0000-0000-0000-000000000002"
            | }
            |
            +-o Volume  <class AppleAPFSVolume, id 0x5, registered, matched, active, busy 0, retain 1>
              | {
              |   "Whole" = No
              |   "BSD Name" = "\(slice)"
              | }
    """
}

private func cliFixture(_ name: String) -> String {
    (try? String(contentsOfFile: fixturePath(name), encoding: .utf8)) ?? ""
}

private extension CLIExecutor {
    /// Every `diskutil` command this runner was asked for, including the ones
    /// scripted to hang.
    var diskutilCalls: Int {
        commands.filter { command in
            switch command {
            case .diskutilList, .diskutilInfo, .diskutilListFilesystems:
                return true
            default:
                return false
            }
        }.count
    }
}
