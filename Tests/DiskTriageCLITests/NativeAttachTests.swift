import Foundation
import Testing
import DiskTriageCollectors
import DiskTriageCore

/// The native attach runner and its cleanup lease, driven through a recorded
/// executor and a recorded attach runner. No `diskutil` process is started.
@Suite(.serialized)
struct NativeAttachTests {
    private func plist(
        filesystem: String?,
        name: String? = nil,
        locked: Bool? = nil,
        encrypted: Bool? = nil,
        wholeDisk: Bool? = nil
    ) -> String {
        var object: [String: Any] = [:]
        if let filesystem { object["FilesystemType"] = filesystem }
        if let name { object["VolumeName"] = name }
        if let locked { object["Locked"] = locked }
        if let encrypted { object["Encrypted"] = encrypted }
        if let wholeDisk { object["WholeDisk"] = wholeDisk }
        let data = try! PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        return String(decoding: data, as: UTF8.self)
    }

    private let apfsAttach = """
    /dev/disk8  \tGUID_partition_scheme
    /dev/disk8s1\tApple_APFS
    /dev/disk9  \tApple_APFS_Container
    /dev/disk9s1\tApple_APFS_Volume
    /dev/disk9s2\tApple_APFS_Volume
    """

    // REQ-0317
    @Test("REQ0317 the attach parser takes the first /dev/disk as the whole disk and names every volume")
    func REQ0317_parsesWholeDiskAndVolumes() throws {
        let executor = RecordingNativeExecutor { command in
            switch command {
            case .nativeInfo(let device) where device == "/dev/disk9s1":
                return .ok(self.plist(filesystem: "apfs", name: "DTAPFS1", locked: false, wholeDisk: false))
            case .nativeInfo(let device) where device == "/dev/disk9s2":
                return .ok(self.plist(filesystem: "apfs", name: "DTAPFS2", locked: false, wholeDisk: false))
            case .nativeInfo:
                return .ok(self.plist(filesystem: nil, wholeDisk: true))
            case .nativeAttach:
                return .ok(self.apfsAttach)
            default:
                return CollectorResult(outcome: .error, stderr: "unexpected \(command)")
            }
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        let result = runner.attachReadOnly(image: "/tmp/image.img")

        guard case .attached(let attachment) = result else {
            Issue.record("expected an attachment, got \(result)")
            return
        }
        #expect(attachment.wholeDisk == "/dev/disk8")
        #expect(attachment.volumes.map(\.device) == ["/dev/disk9s1", "/dev/disk9s2"])
        #expect(attachment.volumes.map(\.name) == ["DTAPFS1", "DTAPFS2"])
        #expect(attachment.volumes.allSatisfy { $0.filesystem == .apfs })
    }

    // REQ-0286, REQ-0306
    @Test("REQ0286_REQ0306 a bare-volume image attaches as one whole disk that is the volume")
    func REQ0286_REQ0306_bareVolumeIsAWholeDiskVolume() {
        let executor = RecordingNativeExecutor { command in
            switch command {
            case .nativeAttach:
                return .ok("/dev/disk8\n")
            case .nativeInfo:
                return .ok(self.plist(filesystem: "hfs", name: "DTHFS", locked: false, wholeDisk: true))
            default:
                return CollectorResult(outcome: .error, stderr: "unexpected")
            }
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        guard case .attached(let attachment) = runner.attachReadOnly(image: "/tmp/hfs.img") else {
            Issue.record("expected an attachment")
            return
        }
        #expect(attachment.wholeDisk == "/dev/disk8")
        #expect(attachment.volumes == [
            NativeAttachedVolume(device: "/dev/disk8", name: "DTHFS", filesystem: .hfsPlus)
        ])
    }

    // REQ-0318, REQ-0283
    @Test("REQ0318_REQ0283 a locked APFS volume is reported as encrypted and locked")
    func REQ0318_REQ0283_lockedVolumeIsDetected() {
        let executor = RecordingNativeExecutor { command in
            switch command {
            case .nativeAttach:
                return .ok("/dev/disk8\tGUID_partition_scheme\n/dev/disk8s1\tApple_APFS_Container\n/dev/disk9s1\tApple_APFS_Volume\n")
            case .nativeInfo(let device) where device == "/dev/disk9s1":
                return .ok(self.plist(filesystem: "apfs", name: "Secret", locked: true))
            case .nativeInfo:
                return .ok(self.plist(filesystem: nil))
            default:
                return CollectorResult(outcome: .error)
            }
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        guard case .attached(let attachment) = runner.attachReadOnly(image: "/tmp/enc.img") else {
            Issue.record("expected an attachment")
            return
        }
        #expect(attachment.volumes.count == 1)
        #expect(attachment.volumes[0].locked)
        #expect(attachment.volumes[0].encrypted, "locked implies encrypted")
    }

    // REQ-0269
    @Test("REQ0269 attach, info, mount, unmount and detach each carry a hard timeout")
    func REQ0269_everyStepHasAHardTimeout() {
        let executor = RecordingNativeExecutor { command in
            switch command {
            case .nativeAttach: return .ok("/dev/disk8\n")
            case .nativeInfo: return .ok(self.plist(filesystem: "exfat", name: "X", wholeDisk: true))
            default: return .ok("")
            }
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        _ = runner.attachReadOnly(image: "/tmp/x.img")
        _ = runner.mountReadOnly(volume: "/dev/disk8", mountPoint: "/tmp/m")
        _ = runner.unmount(volume: "/dev/disk8")
        _ = runner.detach(wholeDisk: "/dev/disk8")

        let timeouts = executor.timeouts
        #expect(timeouts.contains(LiveNativeAttachRunner.attachTimeout))
        #expect(timeouts.contains(LiveNativeAttachRunner.infoTimeout))
        #expect(timeouts.contains(LiveNativeAttachRunner.mountTimeout))
        #expect(timeouts.contains(LiveNativeAttachRunner.unmountTimeout))
        #expect(timeouts.contains(LiveNativeAttachRunner.detachTimeout))
        #expect(LiveNativeAttachRunner.mountTimeout > LiveNativeAttachRunner.attachTimeout,
                "the mount waits for DiskArbitration and gets the longer budget")
    }

    // REQ-0265, REQ-0266, REQ-0319
    @Test("REQ0265_REQ0266_REQ0319 the live runner builds the exact read-only argv shapes")
    func REQ0265_REQ0266_REQ0319_buildsTheReadOnlyShapes() {
        let executor = RecordingNativeExecutor { command in
            switch command {
            case .nativeAttach: return .ok("/dev/disk8\n")
            case .nativeInfo: return .ok(self.plist(filesystem: "exfat", name: "X", wholeDisk: true))
            default: return .ok("")
            }
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        _ = runner.attachReadOnly(image: "/tmp/x.img")
        _ = runner.mountReadOnly(volume: "/dev/disk8", mountPoint: "/tmp/disktriage-mount-x")
        _ = runner.unmount(volume: "/dev/disk8")
        _ = runner.detach(wholeDisk: "/dev/disk8")

        let argv = executor.argvs
        #expect(argv.contains([
            "/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly", "/tmp/x.img",
        ]))
        #expect(argv.contains([
            "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
            "-mountPoint", "/tmp/disktriage-mount-x", "/dev/disk8",
        ]))
        #expect(argv.contains(["/usr/sbin/diskutil", "unmount", "/dev/disk8"]))
        #expect(argv.contains(["/usr/sbin/diskutil", "eject", "/dev/disk8"]))
        for command in argv {
            #expect(CommandPolicy.native.evaluate(command) == .allowed, "\(command)")
        }
    }

    // REQ-0294, REQ-0296
    @Test("REQ0294_REQ0296 a missing diskutil is unavailable, never a writable fallback")
    func REQ0294_REQ0296_missingDiskutilIsUnavailable() {
        let executor = RecordingNativeExecutor { _ in
            CollectorResult(outcome: .notFound, stderr: "not found: /usr/sbin/diskutil")
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        guard case .unavailable(let reason) = runner.attachReadOnly(image: "/tmp/x.img") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("diskutil"))
        #expect(reason.contains("no writable or third-party fallback"))
    }

    // REQ-0295
    @Test("REQ0295 an attach timeout recovers the exact image's disk from hdiutil info")
    func REQ0295_attachTimeoutRecoversTheDisk() {
        let executor = RecordingNativeExecutor { command in
            switch command {
            case .nativeAttach:
                return CollectorResult(outcome: .timeout)
            case .hdiutilInfo:
                return .ok("""
                ================================================
                image-path      : /tmp/x.img
                image-alias     : /tmp/x.img
                writeable       : false
                /dev/disk12\t\t
                ================================================
                image-path      : /tmp/other.img
                /dev/disk13\t\t
                """)
            default:
                return CollectorResult(outcome: .error)
            }
        }
        let runner = LiveNativeAttachRunner(executor: executor)
        guard case .timedOut(_, let disk) = runner.attachReadOnly(image: "/tmp/x.img") else {
            Issue.record("expected a timeout")
            return
        }
        #expect(disk == "/dev/disk12", "only the exact image path is recovered")
    }

    // REQ-0270, REQ-0275, REQ-0274
    @Test("REQ0270_REQ0275_REQ0274 cleanup unmounts the exact volume, then detaches the exact whole disk")
    func REQ0270_REQ0275_REQ0274_cleanupOrderAndExactDevices() {
        let runner = RecordingAttachRunner()
        let lease = NativeAttachmentLease(runner: runner, wholeDisk: "/dev/disk8")
        lease.recordMountAttempt("/dev/disk9s1")

        let outcome = lease.cleanup()
        #expect(outcome.wholeDisk == "/dev/disk8")
        #expect(runner.calls == [.unmount("/dev/disk9s1"), .detach("/dev/disk8")],
                "unmount comes before detach, and nothing else is named")

        _ = lease.cleanup()
        #expect(runner.calls.count == 2, "cleanup is idempotent")
    }

    // REQ-0271
    @Test("REQ0271 cleanup still detaches after a failed mount")
    func REQ0271_cleanupAfterAFailedMount() {
        let runner = RecordingAttachRunner()
        runner.mountResult = .failed("mount failed")
        let lease = NativeAttachmentLease(runner: runner, wholeDisk: "/dev/disk8")
        // The mount was attempted (recorded before the call), then failed.
        lease.recordMountAttempt("/dev/disk8s1")
        _ = lease.cleanup()
        #expect(runner.calls == [.unmount("/dev/disk8s1"), .detach("/dev/disk8")])
    }

    // REQ-0272
    @Test("REQ0272 cleanup still unmounts and detaches after a mount timeout")
    func REQ0272_cleanupAfterAMountTimeout() {
        let runner = RecordingAttachRunner()
        runner.mountResult = .timedOut("mount timed out")
        let lease = NativeAttachmentLease(runner: runner, wholeDisk: "/dev/disk10")
        lease.recordMountAttempt("/dev/disk10s2")
        let outcome = lease.cleanup()
        #expect(runner.calls == [.unmount("/dev/disk10s2"), .detach("/dev/disk10")])
        #expect(outcome.detach == .ok)
    }

    // REQ-0273
    @Test("REQ0273 the SIGINT/SIGTERM path cleans up every live lease and returns 128+signal")
    func REQ0273_signalPathCleansUp() {
        let runner = RecordingAttachRunner()
        let lease = NativeAttachmentLease(runner: runner, wholeDisk: "/dev/disk11")
        lease.recordMountAttempt("/dev/disk11s1")
        let registry = NativeCleanupRegistry()
        registry.register(lease)

        let code = NativeSignalTrap.handleForTesting(SIGTERM, registry: registry)
        #expect(code == 143, "SIGTERM is 128 + 15")
        #expect(runner.calls == [.unmount("/dev/disk11s1"), .detach("/dev/disk11")])
        #expect(registry.liveCount == 0, "the lease is unregistered")
    }

    // REQ-0274
    @Test("REQ0274 a lease cannot detach a disk other than the one it was created with")
    func REQ0274_leaseIsFixedToOneDisk() {
        let runner = RecordingAttachRunner()
        let lease = NativeAttachmentLease(runner: runner, wholeDisk: "/dev/disk14")
        _ = lease.cleanup()
        #expect(runner.calls == [.detach("/dev/disk14")])
        #expect(!runner.calls.contains(.detach("/dev/disk0")))
    }
}

// MARK: - Doubles

private final class RecordingNativeExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(TriageCommand, TimeInterval)] = []
    private let respond: @Sendable (TriageCommand) -> CollectorResult

    init(respond: @escaping @Sendable (TriageCommand) -> CollectorResult) {
        self.respond = respond
    }

    var timeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(\.1)
    }

    var argvs: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(\.0.argv)
    }

    func run(_ command: TriageCommand) -> CollectorResult {
        run(command, timeout: 0)
    }

    func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult {
        lock.lock()
        storage.append((command, timeout))
        lock.unlock()
        return respond(command)
    }
}

enum RecordedNativeCall: Equatable {
    case mount(String)
    case unmount(String)
    case detach(String)
}

final class RecordingAttachRunner: NativeAttachRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedNativeCall] = []
    var mountResult: NativeCommandResult = .ok

    var calls: [RecordedNativeCall] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func attachReadOnly(image: String) -> NativeAttachResult {
        .failed("not used in cleanup tests")
    }

    func mountReadOnly(volume: String, mountPoint: String) -> NativeCommandResult {
        lock.lock()
        storage.append(.mount(volume))
        lock.unlock()
        return mountResult
    }

    func unmount(volume: String) -> NativeCommandResult {
        lock.lock()
        storage.append(.unmount(volume))
        lock.unlock()
        return .ok
    }

    func detach(wholeDisk: String) -> NativeCommandResult {
        lock.lock()
        storage.append(.detach(wholeDisk))
        lock.unlock()
        return .ok
    }
}
