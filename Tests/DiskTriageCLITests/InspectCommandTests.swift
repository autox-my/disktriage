import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCollectors
import DiskTriageCLI

/// `disktriage inspect` through the injected tool runner and the real local
/// filesystem in a temporary directory. No image is a device and no tool runs.
struct InspectCommandTests {
    private let temp = TempDir()


    private static func fixture(_ name: String) throws -> String {
        try String(contentsOfFile: fixturePath(name), encoding: .utf8)
    }

    private static func volumeFixture() throws -> String { try fixture("ntfsinfo-plain.txt") }
    private static func rootFixture() throws -> String { try fixture("ntfsls-root.txt") }
    private static func recursiveFixture() throws -> String { try fixture("ntfsls-recursive.txt") }

    private static func workingTools() throws -> ScriptedNTFSTools {
        ScriptedNTFSTools(
            volume: .ok(try volumeFixture()),
            root: .ok(try rootFixture()),
            recursive: .ok(try recursiveFixture())
        )
    }

    // REQ-0111: inspect takes images only.
    @Test("REQ0055_REQ0111 inspect refuses a /dev node with a usage error")
    func REQ0055_REQ0111_refusesADeviceNode() {
        let result = runInspect(
            arguments: ["/dev/rdisk9"],
            dependencies: inspectDependencies(tools: ScriptedNTFSTools())
        )

        #expect(result.exitCode == 2, "a usage error, not a tool error")
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("/dev"))
        #expect(result.stderr.contains("image"))
    }

    // REQ-0111 / REQ-0123: the textual path may look ordinary; the symlink
    // target is what the /dev refusal must see.
    @Test("REQ0055_REQ0111_REQ0123 a symlink to a device node is refused")
    func REQ0055_REQ0111_REQ0123_symlinkToADeviceIsRefused() throws {
        let directory = URL(fileURLWithPath: try temp.makeDirectory("link"))
        let link = directory.appendingPathComponent("ordinary.img").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/dev/null")

        let result = runInspect(
            arguments: [link],
            dependencies: inspectDependencies(tools: ScriptedNTFSTools())
        )

        #expect(result.exitCode == 2, "a device node behind a symlink is still a device node")
        #expect(result.stderr.contains("/dev/null"), "the message names the resolved target")
    }

    // REQ-0112: a directory, socket or device is not an image file.
    @Test("REQ0112 inspect refuses a non-regular file")
    func REQ0112_refusesANonRegularFile() throws {
        let directory = URL(fileURLWithPath: try temp.makeDirectory("directory"))

        let result = runInspect(
            arguments: [directory.path],
            dependencies: inspectDependencies(tools: ScriptedNTFSTools())
        )

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("regular file"))
    }

    @Test("a missing image is a tool error with an actionable message")
    func missingImageIsToolError() {
        let result = runInspect(
            arguments: ["/definitely/not/here.img"],
            dependencies: inspectDependencies(tools: ScriptedNTFSTools())
        )
        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("no such image"))
    }

    // REQ-0121: missing tools are a precondition error, never a mount fallback.
    @Test("REQ0088_REQ0121 missing ntfs-3g tools exit 30 with the prefix hint, never a mount fallback")
    func REQ0088_REQ0121_missingToolsExitThirty() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let result = runInspect(
            arguments: [image],
            dependencies: InspectDependencies(
                fileSystem: LiveInspectFileSystem(),
                environment: ["PATH": "", "DISKTRIAGE_NTFS_PREFIX": ""],
                tools: nil,
                resolveTools: false
            )
        )

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("DISKTRIAGE_NTFS_PREFIX"))
        #expect(result.stderr.contains("ntfs-3g"))
        #expect(!result.stderr.localizedCaseInsensitiveContains("mount /dev"))
    }

    // REQ-0122: a volume that will not open is exit 30, not a verdict.
    @Test("REQ0122 a volume that cannot be opened exits 30 and keeps the tool error")
    func REQ0122_volumeCannotOpenExitsThirty() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let tools = ScriptedNTFSTools(
            volume: CollectorResult(
                outcome: .error,
                exitCode: 1,
                stderr: try Self.fixture("ntfsinfo-bootsec.stderr.txt")
            )
        )
        let result = runInspect(arguments: [image], dependencies: inspectDependencies(tools: tools))

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("NTFS signature is missing"))
    }

    @Test("a policy rejection names the argument it rejected")
    func policyRejectionNamesTheArgument() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let tools = ScriptedNTFSTools(
            volume: CollectorResult(outcome: .policyRejected, policyViolation: .notAllowListed)
        )
        let result = runInspect(arguments: [image], dependencies: inspectDependencies(tools: tools))

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains(image), "the message names the rejected argument: \(result.stderr)")
        #expect(result.stderr.contains("not-allow-listed"))
    }

    // REQ-0123: the command policy is absolute-only, so the CLI resolves a
    // relative path before the runner (and therefore the policy) sees it.
    @Test("REQ0123 a relative image path is resolved before the command policy")
    func REQ0123_relativeImagePathIsResolvedBeforeThePolicy() throws {
        let directory = URL(fileURLWithPath: try temp.makeDirectory("relative"))

        let absolute = directory.appendingPathComponent("volume.img").path
        var bytes = [UInt8](repeating: 0, count: 65_536)
        bytes.replaceSubrange(0..<512, with: makeBootSector(totalSectors: 127))
        try Data(bytes).write(to: URL(fileURLWithPath: absolute))

        // The policy stays strict: the relative spelling is still rejected.
        #expect(CommandPolicy.inspect.evaluate(
            ["/opt/ntfs/bin/ntfsinfo", "-m", "volume.img"]
        ) != .allowed, "the policy is absolute-only")

        let executor = PolicyEnforcingNTFSExecutor()
        let runner = NTFSToolRunner(
            toolchain: NTFSToolchain(
                ntfsinfo: "/opt/ntfs/bin/ntfsinfo",
                ntfsls: "/opt/ntfs/bin/ntfsls"
            ),
            executor: executor
        )
        let result = runInspect(
            arguments: ["volume.img", "--json"],
            dependencies: InspectDependencies(
                fileSystem: LiveInspectFileSystem(),
                environment: [:],
                tools: runner,
                resolveTools: false,
                currentDirectory: directory.path
            )
        )

        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(!executor.images.isEmpty, "the tools ran")
        #expect(executor.images.allSatisfy { $0 == absolute },
                "the policy saw the resolved absolute path: \(executor.images)")
    }

    // REQ-0123: --mapfile and --to are resolved at the same boundary as the
    // image, so a relative path reaches neither the policy nor the filesystem
    // as a bare relative name.
    @Test("REQ0123 a relative --mapfile and --to are resolved too")
    func REQ0123_relativeMapfileAndWorkingCopyAreResolved() throws {
        let directory = URL(fileURLWithPath: try temp.makeDirectory("relpaths"))

        var bytes = [UInt8](repeating: 0, count: 8192)
        bytes.replaceSubrange(7680..<8192, with: makeBootSector(totalSectors: 15))
        try Data(bytes).write(to: directory.appendingPathComponent("image.img"))
        try Data(try Self.fixture("ntfs-damaged.mapfile.txt").utf8)
            .write(to: directory.appendingPathComponent("damage.map"))

        let result = runInspect(
            arguments: [
                "image.img", "--restore-boot-sector", "--to", "working.img",
                "--mapfile", "damage.map", "--json",
            ],
            dependencies: InspectDependencies(
                fileSystem: LiveInspectFileSystem(),
                environment: [:],
                tools: BootAwareTools(),
                resolveTools: false,
                currentDirectory: directory.path
            )
        )
        #expect(result.exitCode == 1, "the mapfile still reports damage: \(result.stdout) \(result.stderr)")

        let object = try jsonObject(result)
        let boot = try #require(object["boot_sector"] as? [String: Any])
        #expect(boot["working_copy"] as? String
            == directory.appendingPathComponent("working.img").path)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["mapfile"] as? String
            == directory.appendingPathComponent("damage.map").path)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("working.img").path
        ), "the working copy was written where the relative path pointed")
    }

    // REQ-0117: an absent mapfile is unknown damage, never zero.
    @Test("REQ0117 no mapfile reports damage as unknown, not zero")
    func REQ0117_absentMapfileIsUnknownNotZero() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        #expect(result.exitCode == 0, "a healthy volume with no mapfile is not damage")

        let object = try jsonObject(result)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["status"] as? String == "unsupported")
        #expect(damage["unreadable_extents"] == nil, "unknown is not zero")
        #expect(damage["unreadable_bytes"] == nil, "unknown is not zero")
        #expect((damage["note"] as? String)?.contains("absent is never a zero") == true)

        let human = runInspect(
            arguments: [image],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        #expect(human.stdout.contains("damage unknown"))
        #expect(human.stdout.contains("absent is never a zero"))
        #expect(!human.stdout.contains("0 unreadable"))
    }

    // REQ-0124: "no damage note" reads like "no damage". With no mapfile the
    // human RESULT line must say the damage is unknown, matching the JSON.
    @Test("REQ0124 no mapfile: the result line says damage is unknown, not 'no damage'")
    func REQ0124_resultLineSaysDamageUnknownWithoutAMapfile() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let result = runInspect(
            arguments: [image],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("damage UNKNOWN"), "\(result.stdout)")
        #expect(result.stdout.contains("no mapfile"), "\(result.stdout)")
        #expect(!result.stdout.contains("inspected; no damage note"), "\(result.stdout)")
    }

    // REQ-0116: the mapfile's `-` extents are the volume-level damage note.
    @Test("REQ0056_REQ0090_REQ0091_REQ0116 a mapfile reports its unreadable extents and bytes")
    func REQ0056_REQ0090_REQ0091_REQ0116_mapfileReportsDamage() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }
        try Data(try Self.fixture("ntfs-damaged.mapfile.txt").utf8)
            .write(to: URL(fileURLWithPath: image + ".mapfile"))

        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        #expect(result.exitCode == 1, "inspected, but the mapfile reports damage")

        let object = try jsonObject(result)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["status"] as? String == "ok")
        #expect(damage["unreadable_extents"] as? Int == 1)
        #expect(damage["unreadable_bytes"] as? Int == 262_144)
        #expect(damage["scope"] as? String == "volume")
        #expect(damage["attribution"] as? String == "none")
        #expect((damage["note"] as? String)?.contains("zero-filled") == true)

        let human = runInspect(
            arguments: [image],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        #expect(human.stdout.contains("1 unreadable extent"))
        #expect(human.stdout.contains("262144 bytes"))
        #expect(human.stdout.contains("zero-filled"))
        #expect(human.stdout.contains("not proof"))
        #expect(human.stdout.contains("copy"))
        #expect(human.stdout.contains("inspected; mapfile reports damage"))
    }

    // REQ-0172: a mapfile's `*` and `/` extents are unreadable so far even
    // though ddrescue has not yet confirmed them as bad. The real MiNaH run
    // wrote 12 of them and printed "0 unreadable extents".
    @Test("REQ0172 inspect counts failed and bad extents as unreadable, with a shrink note")
    func REQ0172_REQ0177_failedExtentsAreUnreadable() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }
        try Data(try Self.fixture("minah-partial-me.mapfile.txt").utf8)
            .write(to: URL(fileURLWithPath: image + ".mapfile"))

        let json = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        #expect(json.exitCode == 1, "inspected, but the mapfile reports failed extents")

        let object = try jsonObject(json)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["status"] as? String == "ok")
        #expect(damage["unreadable_extents"] as? Int == 12, "failed + bad")
        #expect(damage["unreadable_bytes"] as? Int == 786_432)
        #expect(damage["failed_extents"] as? Int == 12)
        #expect(damage["failed_bytes"] as? Int == 786_432)
        #expect(damage["bad_extents"] as? Int == 0)
        #expect(damage["bad_bytes"] as? Int == 0)
        #expect((damage["note"] as? String)?.contains("may shrink after trimming") == true,
                "\(damage["note"] ?? "no note")")

        let human = runInspect(
            arguments: [image],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        #expect(human.stdout.contains("12 unreadable extents"), "\(human.stdout)")
        #expect(human.stdout.contains("786432 bytes"), "\(human.stdout)")
        #expect(human.stdout.contains("may shrink after trimming"), "\(human.stdout)")
    }

    @Test("a sidecar limit clamps the mapfile before the damage is counted")
    func sidecarLimitClampsTheMapfile() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }
        try Data("""
        {
          "schema": "disktriage.image/1",
          "device": {"size_bytes": 67108864},
          "limit_bytes": 1048576
        }
        """.utf8).write(to: URL(fileURLWithPath: image + ".disktriage.json"))
        try Data("""
        # Mapfile. Created by GNU ddrescue version 1.30
        # Finished
        # current_pos  current_status  current_pass
        0x00000000     +               1
        #      pos        size  status
        0x00000000  0x00080000  +
        0x00080000  0x00040000  -
        0x000C0000  0x7FFFFFFF709AFFFF  ?
        """.utf8).write(to: URL(fileURLWithPath: image + ".mapfile"))

        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        let object = try jsonObject(result)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["unreadable_extents"] as? Int == 1)
        #expect(damage["unreadable_bytes"] as? Int == 262_144)
        #expect(damage["limit_bytes"] as? Int == 1_048_576)
    }

    @Test("an explicit --mapfile wins over the sidecar default")
    func explicitMapfileWins() throws {
        let image = try makeBareNTFSImage()
        let mapfile = image + ".explicit-map"
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: mapfile)
        }
        try Data(try Self.fixture("ntfs-damaged.mapfile.txt").utf8)
            .write(to: URL(fileURLWithPath: mapfile))

        let result = runInspect(
            arguments: [image, "--mapfile", mapfile, "--json"],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )
        let object = try jsonObject(result)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["mapfile"] as? String == mapfile)
        #expect(result.exitCode == 1)
    }

    // REQ-0115: a whole-disk image is extracted before the tools see it, and
    // the extraction is the partition, not the disk.
    @Test("REQ0115 a whole-disk image is extracted to the partition before ntfsinfo runs")
    func REQ0115_extractsThePartition() throws {
        let image = try makeWholeDiskImage()
        defer { try? FileManager.default.removeItem(atPath: image) }
        let originalHash = try sha256(path: image)
        let recorder = ToolRecorder()

        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(
                tools: try workingTools(recorder: recorder)
            )
        )

        #expect(result.exitCode == 0)
        let object = try jsonObject(result)
        let layout = try #require(object["layout"] as? [String: Any])
        #expect(layout["kind"] as? String == "whole-disk")
        #expect(layout["scheme"] as? String == "mbr")
        #expect(layout["partition"] as? Int == 1)
        #expect(layout["offset_bytes"] as? Int == 4096)
        #expect(layout["length_bytes"] as? Int == 65_536)

        let inspected = try #require(recorder.images.first)
        #expect(inspected != image, "the tools never read the whole-disk image")
        let bytes = try #require(recorder.contents.first, "the extract was readable while the tools ran")
        #expect(bytes.count == 65_536, "the extracted file is the partition")
        #expect(bytes.starts(with: Data([0xEB, 0x52, 0x90])), "and it starts at the partition boot sector")
        #expect(!FileManager.default.fileExists(atPath: inspected), "the temporary extract is removed")

        #expect(try sha256(path: image) == originalHash, "the source image was not written")
    }

    @Test("a whole-disk image with no NTFS partition names the filesystem it found")
    func wholeDiskWithoutNTFSNamesTheFilesystem() throws {
        let image = try makeWholeDiskImage(filesystem: .apfs)
        defer { try? FileManager.default.removeItem(atPath: image) }

        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: ScriptedNTFSTools())
        )
        #expect(result.exitCode == 30)
        let object = try jsonObject(result)
        #expect(object["filesystem"] as? String == "apfs")
        #expect((object["message"] as? String)?.contains("native read-only attach not implemented yet") == true)
    }

    // REQ-0120: a bare non-NTFS volume is named, not guessed at.
    @Test("REQ0120 a bare APFS volume is reported as not implemented, exit 30")
    func REQ0120_reportsBareAPFS() throws {
        var bytes = [UInt8](repeating: 0, count: 8192)
        bytes.replaceSubrange(32..<36, with: Array("NXSB".utf8))
        let image = try makeImage(bytes)
        defer { try? FileManager.default.removeItem(atPath: image) }

        let result = runInspect(
            arguments: [image],
            dependencies: inspectDependencies(tools: ScriptedNTFSTools())
        )
        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("apfs"))
        #expect(result.stderr.contains("native read-only attach not implemented yet"))
    }

    // REQ-0113: inspection is read-only; the source hash is unchanged.
    @Test("REQ0009_REQ0010_REQ0088_REQ0113 inspecting a bare image never writes it")
    func REQ0009_REQ0010_REQ0088_REQ0113_bareInspectionIsReadOnly() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }
        let before = try sha256(path: image)
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: image)[.size] as? Int

        _ = runInspect(
            arguments: [image],
            dependencies: inspectDependencies(tools: try Self.workingTools())
        )

        #expect(try sha256(path: image) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: image)[.size] as? Int == sizeBefore)
    }

    @Test("a partially opened volume (stderr on a zero exit) exits 1")
    func partialListingExitsOne() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let stderr = try Self.fixture("ntfsls-damaged-index.stderr.txt")
        let tools = ScriptedNTFSTools(
            volume: .ok(try Self.volumeFixture()),
            root: .ok(try Self.rootFixture(), stderr: stderr),
            recursive: .ok(try Self.recursiveFixture(), stderr: stderr)
        )
        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: tools)
        )

        #expect(result.exitCode == 1)
        let object = try jsonObject(result)
        let listing = try #require(object["listing"] as? [String: Any])
        #expect(listing["status"] as? String == "partial")
        #expect((listing["note"] as? String)?.contains("Corrupt index block") == true)
    }

    @Test("a capped listing is partial, not a complete answer")
    func cappedListingExitsOne() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let tools = ScriptedNTFSTools(
            volume: .ok(try Self.volumeFixture()),
            root: .ok(try Self.rootFixture()),
            recursive: CollectorResult(
                outcome: .ok,
                stdout: try Self.recursiveFixture(),
                stdoutTruncated: true
            )
        )
        let result = runInspect(
            arguments: [image, "--json"],
            dependencies: inspectDependencies(tools: tools)
        )
        #expect(result.exitCode == 1)
        let object = try jsonObject(result)
        let listing = try #require(object["listing"] as? [String: Any])
        #expect(listing["truncated"] as? Bool == true)
    }

    // REQ-0118: the restore runs on a working copy, only when asked.
    @Test("REQ0118_REQ0113 restoring the boot sector writes only the working copy")
    func REQ0118_REQ0113_restoreWritesOnlyTheWorkingCopy() throws {
        let image = try makeImageWithDamagedPrimary()
        let copy = image + ".working"
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: copy)
        }
        let before = try sha256(path: image)
        let tools = BootAwareTools()

        let result = runInspect(
            arguments: [image, "--restore-boot-sector", "--to", copy, "--json"],
            dependencies: inspectDependencies(tools: tools)
        )
        #expect(result.exitCode == 0, "the restored copy opens: \(result.stdout) \(result.stderr)")

        let object = try jsonObject(result)
        let boot = try #require(object["boot_sector"] as? [String: Any])
        #expect(boot["status"] as? String == "restored")
        #expect(boot["working_copy"] as? String == copy)
        #expect(boot["backup_offset_bytes"] as? Int == 7680)

        #expect(try sha256(path: image) == before, "the original image is never written")
        let copyBytes = try Data(contentsOf: URL(fileURLWithPath: copy))
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: image))
        #expect(copyBytes.count == originalBytes.count, "the copy keeps the image size (notrunc)")
        #expect(copyBytes[3..<11] == Data("NTFS    ".utf8), "the copy's primary is restored")
        #expect(copyBytes[7683..<7691] == Data("NTFS    ".utf8), "the backup sector is untouched")
        #expect(tools.images == [copy], "the re-open runs on the working copy")
    }

    @Test("REQ0118 an existing working copy is never overwritten")
    func REQ0118_refusesToOverwriteTheWorkingCopy() throws {
        let image = try makeImageWithDamagedPrimary()
        let copy = image + ".working"
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: copy)
        }
        try Data("do not overwrite me".utf8).write(to: URL(fileURLWithPath: copy))
        let before = try sha256(path: image)

        let result = runInspect(
            arguments: [image, "--restore-boot-sector", "--to", copy],
            dependencies: inspectDependencies(tools: BootAwareTools())
        )
        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("exists"))
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == "do not overwrite me")
        #expect(try sha256(path: image) == before)
    }

    // REQ-0119: the backup offset is the partition's last sector, not the
    // disk's. A decoy valid sector at the disk end must not be used.
    @Test("REQ0119 a whole-disk restore reads the partition end, not the disk end")
    func REQ0119_restoreUsesThePartitionEnd() throws {
        let image = try makeWholeDiskImage()
        let copy = image + ".working"
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: copy)
        }

        // Damage the primary but keep the true backup (partition end).
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: image))
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0, count: 512))
        try handle.close()

        // The true backup at the partition end (4096 + 65536 - 512).
        let trueBackup = makeBootSector(totalSectors: 127)
        try write(trueBackup, to: image, offset: 69_120)

        // A decoy valid boot sector at the image's absolute last sector.
        let diskSize = try FileManager.default.attributesOfItem(atPath: image)[.size] as! Int
        var decoy = makeBootSector(totalSectors: 126)
        decoy[100] = 0xC0
        try write(decoy, to: image, offset: Int64(diskSize - 512))

        let result = runInspect(
            arguments: [image, "--restore-boot-sector", "--to", copy, "--json"],
            dependencies: inspectDependencies(tools: BootAwareTools())
        )
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")

        let object = try jsonObject(result)
        let boot = try #require(object["boot_sector"] as? [String: Any])
        #expect(boot["backup_offset_bytes"] as? Int == 69_120, "partition end: 4096 + 65536 - 512")

        let copyBytes = try Data(contentsOf: URL(fileURLWithPath: copy))
        let restoredTotalSectors = copyBytes[0x28 + 4096]
        #expect(restoredTotalSectors == 127, "the true backup was copied, not the disk-end decoy")
    }

    @Test("REQ0118 an invalid backup sector reports that the volume cannot be restored")
    func REQ0118_invalidBackupCannotRestore() throws {
        var bytes = [UInt8](repeating: 0, count: 8192)
        bytes[0] = 0x00 // primary invalid
        let image = try makeImage(bytes)
        let copy = image + ".working"
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: copy)
        }
        let mapfile = image + ".mapfile"
        try Data(try Self.fixture("ntfs-damaged.mapfile.txt").utf8)
            .write(to: URL(fileURLWithPath: mapfile))
        defer { try? FileManager.default.removeItem(atPath: mapfile) }

        let result = runInspect(
            arguments: [image, "--restore-boot-sector", "--to", copy, "--json"],
            dependencies: inspectDependencies(tools: BootAwareTools())
        )
        #expect(result.exitCode == 30)

        let object = try jsonObject(result)
        let boot = try #require(object["boot_sector"] as? [String: Any])
        #expect(boot["status"] as? String == "restore-unavailable")
        #expect((boot["reason"] as? String)?.contains("backup") == true)
        let damage = try #require(object["damage"] as? [String: Any])
        #expect(damage["unreadable_extents"] as? Int == 1, "volume-level damage is still reported")
    }

    @Test("--to without --restore-boot-sector is a usage error, and vice versa")
    func restoreAndToMustTravelTogether() throws {
        let image = try makeBareNTFSImage()
        defer { try? FileManager.default.removeItem(atPath: image) }

        let toOnly = runInspect(arguments: [image, "--to", "/tmp/x"], dependencies: inspectDependencies(tools: ScriptedNTFSTools()))
        #expect(toOnly.exitCode == 2)

        let restoreOnly = runInspect(arguments: [image, "--restore-boot-sector"], dependencies: inspectDependencies(tools: ScriptedNTFSTools()))
        #expect(restoreOnly.exitCode == 2)
    }

    @Test("inspect --help exits 0 and reads nothing")
    func helpExitsZero() {
        let result = runInspect(arguments: ["--help"], dependencies: nil)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("usage: disktriage inspect"))
        #expect(result.stderr.isEmpty)
    }

    // MARK: - Support

    private func inspectDependencies(tools: (any NTFSToolRunning)?) -> InspectDependencies {
        InspectDependencies(
            fileSystem: LiveInspectFileSystem(),
            environment: [:],
            tools: tools,
            resolveTools: false
        )
    }

    private func makeBareNTFSImage() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let boot = makeBootSector(totalSectors: 127)
        bytes.replaceSubrange(0..<512, with: boot)
        return try makeImage(bytes)
    }

    /// A 128 KiB disk: MBR, one type-0x07 partition of 65536 bytes at byte
    /// 4096, and a valid NTFS boot sector at the partition start.
    private func makeWholeDiskImage(filesystem: BareFilesystem = .ntfs) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 131_072)
        bytes[446 + 4] = 0x07
        putLE32(&bytes, at: 446 + 8, value: 8)        // start LBA
        putLE32(&bytes, at: 446 + 12, value: 128)     // 65536 bytes
        bytes[510] = 0x55
        bytes[511] = 0xAA

        switch filesystem {
        case .ntfs:
            let boot = makeBootSector(totalSectors: 127)
            bytes.replaceSubrange(4096..<4608, with: boot)
        case .apfs:
            bytes.replaceSubrange(4096 + 32..<4096 + 36, with: Array("NXSB".utf8))
        }
        return try makeImage(bytes)
    }

    private func makeImageWithDamagedPrimary() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let backup = makeBootSector(totalSectors: 15)
        bytes.replaceSubrange(7680..<8192, with: backup)
        return try makeImage(bytes)
    }

    private func makeImage(_ bytes: [UInt8]) throws -> String {
        let path = temp.child("inspect-\(UUID().uuidString).img")
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeBootSector(totalSectors: UInt64) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: 512)
        sector.replaceSubrange(0..<3, with: [0xEB, 0x52, 0x90])
        sector.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        sector[0x0B] = 0x00
        sector[0x0C] = 0x02 // 512 bytes per sector
        sector[0x0D] = 8    // 4096-byte clusters
        for i in 0..<8 {
            sector[0x28 + i] = UInt8((totalSectors >> (8 * UInt64(i))) & 0xFF)
        }
        sector[510] = 0x55
        sector[511] = 0xAA
        return sector
    }

    private func putLE32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }

    private func write(_ bytes: [UInt8], to path: String, offset: Int64) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(bytes))
        try handle.close()
    }

    private func sha256(path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func jsonObject(_ result: CLIResult) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    enum BareFilesystem { case ntfs, apfs }
}

// MARK: - Scripted tools

private struct ScriptedNTFSTools: NTFSToolRunning {
    var volume: CollectorResult = .ok("")
    var root: CollectorResult = .ok("")
    var recursive: CollectorResult = .ok("")
    var onVolume: (@Sendable (String) -> Void)?
    var onListing: (@Sendable (String) -> Void)?

    func volumeInfo(image: String) -> CollectorResult {
        onVolume?(image)
        return volume
    }

    func listing(image: String, recursive: Bool) -> CollectorResult {
        onListing?(image)
        return recursive ? self.recursive : root
    }
}

/// The real inspect policy is applied to the argv the runner builds, so a
/// relative image path is rejected exactly as the shipped `ProcessRunner`
/// would reject it. Allowed shapes return the recorded fixtures.
private final class PolicyEnforcingNTFSExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var images: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func run(_ command: TriageCommand) -> CollectorResult {
        run(command, timeout: 0)
    }

    func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult {
        switch CommandPolicy.inspect.evaluate(command.argv) {
        case .rejected(let violation):
            return CollectorResult(outcome: .policyRejected, policyViolation: violation)
        case .allowed:
            let argv = command.argv
            let tool = (argv[0] as NSString).lastPathComponent
            lock.lock()
            storage.append(argv[2])
            lock.unlock()
            if tool == "ntfsinfo" {
                return .ok(try! InspectCommandTests.volumeFixtureText())
            }
            return .ok(argv[1] == "-R"
                ? (try! InspectCommandTests.recursiveFixtureText())
                : (try! InspectCommandTests.rootFixtureText()))
        }
    }
}

/// A fake ntfsinfo: it opens the path it is given and "succeeds" only when the
/// sector at offset 0 has the NTFS OEM ID. That is enough to prove the restore
/// happened on the file the tools then see.
private final class BootAwareTools: NTFSToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var images: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func volumeInfo(image: String) -> CollectorResult {
        lock.lock()
        seen.append(image)
        lock.unlock()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: image)), data.count >= 11 else {
            return CollectorResult(outcome: .error, exitCode: 1, stderr: "cannot read \(image)")
        }
        let oem = data[3..<11]
        guard oem == Data("NTFS    ".utf8) else {
            return CollectorResult(outcome: .error, exitCode: 1, stderr: "NTFS signature is missing.")
        }
        return .ok(try! InspectCommandTests.volumeFixtureText())
    }

    func listing(image: String, recursive: Bool) -> CollectorResult {
        .ok(recursive
            ? (try! InspectCommandTests.recursiveFixtureText())
            : (try! InspectCommandTests.rootFixtureText()))
    }
}

private final class ToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var captured: [Data] = []

    var images: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var contents: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func record(_ image: String) {
        let data = try? Data(contentsOf: URL(fileURLWithPath: image))
        lock.lock()
        storage.append(image)
        if let data { captured.append(data) }
        lock.unlock()
    }
}

private extension InspectCommandTests {
    static func volumeFixtureText() throws -> String { try fixture("ntfsinfo-plain.txt") }
    static func rootFixtureText() throws -> String { try fixture("ntfsls-root.txt") }
    static func recursiveFixtureText() throws -> String { try fixture("ntfsls-recursive.txt") }
}

private extension InspectCommandTests {
    func workingTools(recorder: ToolRecorder) throws -> ScriptedNTFSTools {
        ScriptedNTFSTools(
            volume: .ok(try Self.volumeFixtureText()),
            root: .ok(try Self.rootFixtureText()),
            recursive: .ok(try Self.recursiveFixtureText()),
            onVolume: { recorder.record($0) }
        )
    }
}
