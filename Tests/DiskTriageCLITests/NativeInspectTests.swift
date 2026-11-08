import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCollectors
import DiskTriageCore
import DiskTriageCLI

/// `inspect` on a native filesystem: a scripted attach, a real temporary
/// "mounted" tree, and the live reader. No `diskutil` runs.
struct NativeInspectTests {
    private let temp = TempDir()

    private func makeDependencies(_ runner: any NativeAttachRunning) -> InspectDependencies {
        InspectDependencies(
            fileSystem: LiveInspectFileSystem(),
            environment: [:],
            tools: nil,
            resolveTools: false,
            currentDirectory: temp.path,
            executablePath: nil,
            native: runner,
            mountReader: LiveMountedVolumeReader(),
            resolveNative: false,
            installSignalTrap: false,
            mountPointRoot: temp.path
        )
    }

    private func image(_ filesystem: NativeFilesystem, name: String? = nil) throws -> String {
        let path = temp.child((name ?? "image") + "-\(UUID().uuidString).img")
        try Data(syntheticImageBytes(filesystem: filesystem)).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func wholeDisk(_ filesystem: NativeFilesystem) throws -> String {
        let path = temp.child("disk-\(UUID().uuidString).img")
        try Data(syntheticWholeDiskBytes(filesystem: filesystem)).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func tree() -> [String: ScriptedNativeRunner.Item] {
        [
            "docs": .directory,
            "docs/readme.txt": .file(Data("disktriage native fixture\n".utf8)),
            "empty": .directory,
            "media/payload.bin": .file(Data(repeating: 0xAB, count: 4096)),
            "docs/résumé-日本語.txt": .file(Data("unicode\n".utf8)),
        ]
    }

    private func json(_ result: CLIResult) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    private func sha256(_ path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // REQ-0307, REQ-0298, REQ-0319
    @Test("REQ0292_REQ0307_REQ0298_REQ0319 a bare exFAT image is attached read-only, listed, unmounted and detached")
    func REQ0292_REQ0307_REQ0298_REQ0319_bareExfat() throws {
        let path = try image(.exfat)
        let before = try sha256(path)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DTEXFAT", .exfat, false)]),
            tree: tree()
        )

        let result = runInspect(arguments: [path, "--json"], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")

        let object = try json(result)
        #expect(object["filesystem"] as? String == "exfat")
        let attach = try #require(object["attach"] as? [String: Any])
        #expect(attach["mode"] as? String == "read-only")
        #expect(attach["whole_disk"] as? String == "/dev/disk8")
        #expect(attach["no_mount"] as? Bool == true)
        let volumes = try #require(object["volumes"] as? [[String: Any]])
        #expect(volumes.count == 1)
        #expect(volumes[0]["status"] as? String == "ok")
        #expect(volumes[0]["name"] as? String == "DTEXFAT")
        let rootEntries = volumes[0]["root_entries"] as? Int
        #expect(rootEntries == 3, "docs, empty and media; got \(String(describing: rootEntries))")
        #expect(volumes[0]["recursive_entries"] as? Int == 6)

        #expect(runner.calls == [
            "attach:\(path)",
            "mount:/dev/disk8",
            "unmount:/dev/disk8",
            "detach:/dev/disk8",
        ], "attach, mount, unmount, detach: \(runner.calls)")
        #expect(try sha256(path) == before, "the image was never written")
        #expect(!FileManager.default.fileExists(atPath: temp.path + "/disktriage-mount-leftover"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            .filter { $0.hasPrefix("disktriage-mount-") }
        #expect(leftovers.isEmpty, "the mountpoint was removed: \(leftovers)")
    }

    // REQ-0306
    @Test("REQ0285_REQ0306 a whole-disk HFS+ image reports the partition layout and mounts read-only")
    func REQ0285_REQ0306_wholeDiskHFS() throws {
        let path = try wholeDisk(.hfsPlus)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(
                wholeDisk: "/dev/disk8",
                volumes: [("/dev/disk9s1", "DTHFS", .hfsPlus, false)]
            ),
            tree: tree()
        )

        let result = runInspect(arguments: [path, "--json"], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        let object = try json(result)
        #expect(object["filesystem"] as? String == "hfs+")
        let layout = try #require(object["layout"] as? [String: Any])
        #expect(layout["kind"] as? String == "whole-disk")
        #expect(layout["partition"] as? Int == 1)
        #expect(layout["offset_bytes"] as? Int == 4096)
    }

    // REQ-0308
    @Test("REQ0308 a bare FAT image is inspected")
    func REQ0308_bareFAT() throws {
        let path = try image(.fat)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DTFAT", .fat, false)]),
            tree: tree()
        )
        let result = runInspect(arguments: [path, "--json"], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(try json(result)["filesystem"] as? String == "fat")
    }

    // REQ-0287, REQ-0305
    @Test("REQ0287_REQ0305 an APFS container lists every volume and its device")
    func REQ0287_REQ0305_apfsListsEveryVolume() throws {
        let path = try image(.apfs)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(
                wholeDisk: "/dev/disk8",
                volumes: [
                    ("/dev/disk9s1", "DTAPFS1", .apfs, false),
                    ("/dev/disk9s2", "DTAPFS2", .apfs, false),
                ]
            ),
            tree: tree()
        )
        let result = runInspect(arguments: [path, "--json"], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        let object = try json(result)
        let volumes = try #require(object["volumes"] as? [[String: Any]])
        #expect(volumes.map { $0["name"] as? String } == ["DTAPFS1", "DTAPFS2"])
        #expect(volumes.map { $0["device"] as? String } == ["/dev/disk9s1", "/dev/disk9s2"])
        #expect(runner.calls == [
            "attach:\(path)",
            "mount:/dev/disk9s1", "unmount:/dev/disk9s1",
            "mount:/dev/disk9s2", "unmount:/dev/disk9s2",
            "detach:/dev/disk8",
        ])
    }

    // REQ-0283, REQ-0284
    @Test("REQ0283_REQ0284 a locked encrypted APFS volume is refused without a passphrase prompt")
    func REQ0283_REQ0284_lockedVolumeIsRefused() throws {
        let path = try image(.apfs)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(
                wholeDisk: "/dev/disk8",
                volumes: [("/dev/disk9s1", "Secret", .apfs, true)]
            )
        )
        let result = runInspect(arguments: [path], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("encrypted and locked"))
        #expect(result.stderr.contains("never prompts for a passphrase"))
        #expect(runner.calls == ["attach:\(path)", "detach:/dev/disk8"],
                "nothing was mounted: \(runner.calls)")
    }

    // REQ-0279, REQ-0280
    @Test("REQ0279_REQ0280 mapfile damage is reported at volume level and says regions are zero-filled")
    func REQ0279_REQ0280_damageIsVolumeLevel() throws {
        let path = try image(.exfat)
        try Data(try String(contentsOfFile: fixturePath("ntfs-damaged.mapfile.txt"), encoding: .utf8).utf8)
            .write(to: URL(fileURLWithPath: path + ".mapfile"))
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runInspect(arguments: [path, "--json"], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 1, "damage is exit 1: \(result.stdout) \(result.stderr)")
        let damage = try #require(try json(result)["damage"] as? [String: Any])
        #expect(damage["status"] as? String == "ok")
        #expect(damage["scope"] as? String == "volume")
        #expect(damage["unreadable_extents"] as? Int == 1)
        #expect((damage["note"] as? String)?.contains("zero-filled") == true)
    }

    // REQ-0282
    @Test("REQ0282 inspect says per-file attribution is unavailable for a native filesystem")
    func REQ0282_saysAttributionIsUnavailable() throws {
        let path = try image(.exfat)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runInspect(arguments: [path], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("per-file attribution is not available"))
        #expect(result.stdout.contains("F_LOG2PHYS_EXT"))
        #expect(result.stdout.contains("volume level"))
    }

    // REQ-0294, REQ-0296
    @Test("REQ0294_REQ0296 a missing native runner exits 30 and never falls back")
    func REQ0294_REQ0296_missingRunnerExitsThirty() throws {
        let path = try image(.exfat)
        let result = runInspect(arguments: [path], dependencies: makeDependencies(UnavailableNativeRunner()))
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("unavailable"))
        #expect(result.stderr.localizedCaseInsensitiveContains("no writable or third-party fallback"))
    }

    // REQ-0295, REQ-0272
    @Test("REQ0295_REQ0272 a mount timeout exits 30 and still unmounts and detaches")
    func REQ0295_REQ0272_mountTimeoutExitsThirty() throws {
        let path = try image(.exfat)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        runner.mountResult = .timedOut("mount timed out")
        let result = runInspect(arguments: [path], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(runner.calls == [
            "attach:\(path)", "mount:/dev/disk8", "unmount:/dev/disk8", "detach:/dev/disk8",
        ])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            .filter { $0.hasPrefix("disktriage-mount-") }
        #expect(leftovers.isEmpty)
    }

    // REQ-0300, REQ-0312
    @Test("REQ0300_REQ0312 symlinks are not followed and unicode names survive")
    func REQ0300_REQ0312_symlinksAndUnicode() throws {
        let path = try image(.exfat)
        var tree = tree()
        tree["link-to-etc"] = .symlink("/etc/passwd")
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree
        )
        let result = runInspect(arguments: [path], dependencies: makeDependencies(runner))
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("symbolic link(s) were not followed"))
        #expect(result.stdout.contains("6 recursive entries") || result.stdout.contains("5 recursive entries"))
    }

    // REQ-0309
    @Test("REQ0309 NTFS stays on the ntfs-3g userspace path and never attaches natively")
    func REQ0309_ntfsStaysOnTheUserspacePath() throws {
        let path = try image(.exfat, name: "ntfs")
        // Overwrite with an NTFS boot sector so detectLayout picks NTFS.
        var bytes = [UInt8](repeating: 0, count: 65_536)
        bytes.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        bytes.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        bytes[0x0B] = 0x00
        bytes[0x0C] = 0x02
        bytes[0x0D] = 8
        bytes[510] = 0x55
        bytes[511] = 0xAA
        try Data(bytes).write(to: URL(fileURLWithPath: path))

        let native = ScriptedNativeRunner(attachResult: .failed("must not be called"))
        let tools = StubNTFSTools()
        var deps = makeDependencies(native)
        deps.tools = tools
        let result = runInspect(arguments: [path, "--json"], dependencies: deps)
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(try json(result)["filesystem"] as? String == "ntfs")
        #expect(native.calls.isEmpty, "the native runner was never used")
        #expect(!tools.images.isEmpty)
    }

    // REQ-0310
    @Test("REQ0310 an unrecognised filesystem is still refused, not attached")
    func REQ0310_unknownFilesystemIsRefused() throws {
        let path = temp.child("unknown.img")
        try Data([UInt8](repeating: 0, count: 4096)).write(to: URL(fileURLWithPath: path))
        let native = ScriptedNativeRunner(attachResult: .failed("must not be called"))
        let result = runInspect(arguments: [path], dependencies: makeDependencies(native))
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(native.calls.isEmpty)
    }

    // REQ-0297
    @Test("REQ0297 a device node is a usage error and never reaches the native attach")
    func REQ0297_refusesADeviceNode() {
        let native = ScriptedNativeRunner(attachResult: .failed("must not be called"))
        let result = runInspect(arguments: ["/dev/rdisk9"], dependencies: makeDependencies(native))
        #expect(result.exitCode == 2, "\(result.stdout) \(result.stderr)")
        #expect(native.calls.isEmpty)
    }
}

// MARK: - NTFS stub

private final class StubNTFSTools: NTFSToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var images: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func volumeInfo(image: String) -> CollectorResult {
        lock.lock()
        storage.append(image)
        lock.unlock()
        return .ok(try! String(contentsOfFile: fixturePath("ntfsinfo-plain.txt"), encoding: .utf8))
    }

    func listing(image: String, recursive: Bool) -> CollectorResult {
        .ok(try! String(
            contentsOfFile: fixturePath(recursive ? "ntfsls-recursive.txt" : "ntfsls-root.txt"),
            encoding: .utf8
        ))
    }
}
