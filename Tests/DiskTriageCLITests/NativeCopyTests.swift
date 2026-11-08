import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCollectors
import DiskTriageCore
import DiskTriageCLI

/// `copy` on a native filesystem: a scripted attach, a real temporary
/// "mounted" tree, the shared copy loop and the existing manifest rules.
struct NativeCopyTests {
    private let temp = TempDir()

    private func makeDependencies(
        _ runner: any NativeAttachRunning,
        reader: any MountedVolumeReading = LiveMountedVolumeReader(),
        chunkSize: Int = 1024
    ) -> CopyDependencies {
        CopyDependencies(
            fileSystem: LiveCopyFileSystem(),
            environment: [:],
            tools: nil,
            resolveTools: false,
            currentDirectory: temp.path,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            chunkSize: chunkSize,
            maxBytesOverride: nil,
            chunkObserver: nil,
            executablePath: nil,
            native: runner,
            mountReader: reader,
            resolveNative: false,
            installSignalTrap: false,
            mountPointRoot: temp.path
        )
    }

    private func image(_ filesystem: NativeFilesystem = .exfat) throws -> String {
        let path = temp.child("image-\(UUID().uuidString).img")
        try Data(syntheticImageBytes(filesystem: filesystem)).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func tree() -> [String: ScriptedNativeRunner.Item] {
        [
            "docs": .directory,
            "docs/readme.txt": .file(Data("disktriage native fixture\n".utf8)),
            "empty": .directory,
            "media/payload.bin": .file(Data((0..<4096).map { UInt8($0 % 251) })),
            "docs/résumé-日本語.txt": .file(Data("unicode\n".utf8)),
        ]
    }

    private func json(_ path: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any]
        )
    }

    private func sha256(_ path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // REQ-0288
    @Test("REQ0288 a multi-volume APFS image refuses to copy without --volume")
    func REQ0288_requiresVolumeWhenMoreThanOne() throws {
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
        let result = runCopy(
            arguments: [path, "--to", temp.child("out")],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("--volume"))
        #expect(result.stderr.contains("DTAPFS1"))
        #expect(result.stderr.contains("DTAPFS2"))
        #expect(runner.calls == ["attach:\(path)", "detach:/dev/disk8"], "nothing was mounted")
    }

    // REQ-0289
    @Test("REQ0289 --volume selects by 1-based index")
    func REQ0289_selectsByIndex() throws {
        let path = try image(.apfs)
        let destination = temp.child("out-index")
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
        let result = runCopy(
            arguments: [path, "--to", destination, "--volume", "2", "--json"],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let volume = try #require(object["volume"] as? [String: Any])
        #expect(volume["index"] as? Int == 2)
        #expect(volume["name"] as? String == "DTAPFS2")
        #expect(runner.calls == [
            "attach:\(path)", "mount:/dev/disk9s2", "unmount:/dev/disk9s2",
            "detach:/dev/disk8",
        ])
    }

    // REQ-0290
    @Test("REQ0290 --volume selects by name, case-insensitively")
    func REQ0290_selectsByName() throws {
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
        let result = runCopy(
            arguments: [path, "--to", temp.child("out-name"), "--volume", "dtapfs1"],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(runner.calls.contains("mount:/dev/disk9s1"))
        #expect(!runner.calls.contains("mount:/dev/disk9s2"))
    }

    // REQ-0291
    @Test("REQ0291 an unknown --volume is refused with the available list")
    func REQ0291_refusesUnknownVolume() throws {
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
        let result = runCopy(
            arguments: [path, "--to", temp.child("out-unknown"), "--volume", "nope"],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("does not name exactly one volume"))
        #expect(result.stderr.contains("DTAPFS1"))
    }

    // REQ-0303, REQ-0304, REQ-0314, REQ-0312
    @Test("REQ0303_REQ0304_REQ0314_REQ0312 the copy hashes the bytes read and written and preserves names")
    func REQ0303_REQ0304_REQ0314_REQ0312_hashesAndNames() throws {
        let path = try image()
        let destination = temp.child("out-hash")
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runCopy(
            arguments: [path, "--to", destination],
            dependencies: makeDependencies(runner, chunkSize: 512)
        )
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")

        let manifest = try json(destination + "/MANIFEST.json")
        let files = try #require(manifest["files"] as? [[String: Any]])
        let payload = try #require(files.first { $0["path"] as? String == "media/payload.bin" })
        #expect(payload["status"] as? String == "ok")
        #expect(payload["size_bytes"] as? Int64 == 4096, "the actual byte count, not a guess")
        #expect(payload["sha256_read"] as? String == payload["sha256_written"] as? String)
        let copied = destination + "/media/payload.bin"
        #expect(try sha256(copied) == payload["sha256_read"] as? String)

        #expect(result.stdout.contains("proves the copy matches the IMAGE"),
                "the output says hash equality is against the image, not the platter")
        let unicode = try #require(files.first { $0["path"] as? String == "docs/résumé-日本語.txt" })
        #expect(unicode["status"] as? String == "ok")
        #expect(FileManager.default.fileExists(atPath: destination + "/docs/résumé-日本語.txt"))
    }

    // REQ-0313
    @Test("REQ0313 an empty directory is recreated")
    func REQ0313_recreatesEmptyDirectories() throws {
        let path = try image()
        let destination = temp.child("out-empty-dir")
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runCopy(
            arguments: [path, "--to", destination],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: destination + "/empty",
            isDirectory: &isDirectory
        ) && isDirectory.boolValue)
    }

    // REQ-0302
    @Test("REQ0302 copy never overwrites an existing destination file")
    func REQ0302_neverOverwrites() throws {
        let path = try image()
        let destination = temp.child("out-existing")
        try FileManager.default.createDirectory(
            atPath: destination + "/docs",
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: URL(fileURLWithPath: destination + "/docs/readme.txt"))
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runCopy(
            arguments: [path, "--to", destination],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("already exists"))
        #expect(try String(contentsOfFile: destination + "/docs/readme.txt", encoding: .utf8) == "keep")
    }

    // REQ-0281, REQ-0293, REQ-0282
    @Test("REQ0281_REQ0293_REQ0282 mapfile damage is volume-level, the manifest keeps schema 1, attribution is none")
    func REQ0281_REQ0293_REQ0282_damageAndManifest() throws {
        let path = try image()
        try Data(try String(contentsOfFile: fixturePath("ntfs-damaged.mapfile.txt"), encoding: .utf8).utf8)
            .write(to: URL(fileURLWithPath: path + ".mapfile"))
        let destination = temp.child("out-damage")
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runCopy(
            arguments: [path, "--to", destination],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 1, "damage is exit 1: \(result.stdout) \(result.stderr)")

        let manifest = try json(destination + "/MANIFEST.json")
        #expect(manifest["schema"] as? String == "disktriage.copy/1")
        let damage = try #require(manifest["damage"] as? [String: Any])
        #expect(damage["scope"] as? String == "volume")
        #expect(damage["unreadable_extents"] as? Int == 1)
        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "none")
        #expect((attribution["reason"] as? String)?.contains("F_LOG2PHYS_EXT") == true)
        #expect((attribution["reason"] as? String)?.contains("volume level") == true)
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.allSatisfy { $0["integrity"] == nil },
                "no per-file integrity claim is made for a native filesystem")
    }

    // REQ-0301, REQ-0300
    @Test("REQ0301_REQ0300 a capped listing or a skipped symlink makes the copy partial")
    func REQ0301_REQ0300_partialListing() throws {
        let path = try image()
        let destination = temp.child("out-partial")
        var tree = tree()
        tree["link"] = .symlink("/etc/passwd")
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree
        )
        let result = runCopy(
            arguments: [path, "--to", destination],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 1, "\(result.stdout) \(result.stderr)")
        let manifest = try json(destination + "/MANIFEST.json")
        let copy = try #require(manifest["copy"] as? [String: Any])
        #expect(copy["status"] as? String == "partial")
        #expect((manifest["notes"] as? [String])?.contains {
            $0.contains("symbolic link(s) were not followed")
        } == true)
        #expect(!FileManager.default.fileExists(atPath: destination + "/link"))
    }

    // REQ-0283
    @Test("REQ0283 copy refuses a locked encrypted volume without a passphrase prompt")
    func REQ0283_refusesLockedVolume() throws {
        let path = try image(.apfs)
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(
                wholeDisk: "/dev/disk8",
                volumes: [("/dev/disk9s1", "Secret", .apfs, true)]
            )
        )
        let result = runCopy(
            arguments: [path, "--to", temp.child("out-locked")],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("encrypted and locked"))
        #expect(result.stderr.contains("never prompts for a passphrase"))
        #expect(runner.calls == ["attach:\(path)", "detach:/dev/disk8"])
    }

    // REQ-0299, REQ-0298, REQ-0319
    @Test("REQ0299_REQ0298_REQ0319 the mountpoint is removed, the image is unchanged and cleanup is ordered")
    func REQ0299_REQ0298_REQ0319_cleanupAndReadOnly() throws {
        let path = try image()
        let before = try sha256(path)
        let destination = temp.child("out-clean")
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runCopy(
            arguments: [path, "--to", destination],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(try sha256(path) == before, "the image was never written")
        #expect(runner.calls == [
            "attach:\(path)", "mount:/dev/disk8", "unmount:/dev/disk8", "detach:/dev/disk8",
        ])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            .filter { $0.hasPrefix("disktriage-mount-") }
        #expect(leftovers.isEmpty)
    }

    // REQ-0311
    @Test("REQ0311 --volume is a usage error on an NTFS image")
    func REQ0311_volumeOnNTFSIsUsage() throws {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        bytes.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        bytes.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        bytes[0x0B] = 0x00
        bytes[0x0C] = 0x02
        bytes[0x0D] = 8
        bytes[510] = 0x55
        bytes[511] = 0xAA
        let path = temp.child("ntfs-volume.img")
        try Data(bytes).write(to: URL(fileURLWithPath: path))

        let result = runCopy(
            arguments: [path, "--to", temp.child("ntfs-volume-out"), "--volume", "1"],
            dependencies: makeDependencies(ScriptedNativeRunner(attachResult: .failed("no")))
        )
        #expect(result.exitCode == 2, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("NTFS"))
    }

    // REQ-0297
    @Test("REQ0297 a device node is a usage error and never reaches the native attach")
    func REQ0297_refusesADeviceNode() {
        let native = ScriptedNativeRunner(attachResult: .failed("must not be called"))
        let result = runCopy(
            arguments: ["/dev/rdisk9", "--to", temp.child("device-out")],
            dependencies: makeDependencies(native)
        )
        #expect(result.exitCode == 2, "\(result.stdout) \(result.stderr)")
        #expect(native.calls.isEmpty)
    }

    // REQ-0292
    @Test("REQ0292 copy's JSON reports the exit code and the selected volume")
    func REQ0292_jsonExitCodeAndVolume() throws {
        let path = try image()
        let runner = ScriptedNativeRunner(
            attachResult: nativeAttachment(volumes: [("/dev/disk8", "DT", .exfat, false)]),
            tree: tree()
        )
        let result = runCopy(
            arguments: [path, "--to", temp.child("out-json"), "--json"],
            dependencies: makeDependencies(runner)
        )
        #expect(result.exitCode == 0)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["exit_code"] as? Int == 0)
        #expect(object["filesystem"] as? String == "exfat")
        let attach = try #require(object["attach"] as? [String: Any])
        #expect(attach["mode"] as? String == "read-only")
    }
}
