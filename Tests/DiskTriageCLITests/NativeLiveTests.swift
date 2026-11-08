import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCollectors
import DiskTriageCore
import DiskTriageCLI

/// Live tests on the synthetic native images `scripts/bootstrap.sh` builds.
/// They really attach, mount, unmount and detach the images on this Mac; they
/// run only when the fixtures are present, and a missing fixture is a skip
/// (the gate answers 3, never a pass). Every image is copied into this test's
/// temp directory first, so a leak is visible to the gate's native leak guard.
@Suite(.serialized)
struct NativeLiveTests {
    private let temp = TempDir()

    private func fixtureDirectory() -> String? {
        TestFixtures.nativeFixtureDirectory()
    }

    private func copyFixture(_ name: String) throws -> String {
        let directory = try #require(fixtureDirectory())
        let source = directory + "/" + name
        let destination = temp.child(name)
        try? FileManager.default.removeItem(atPath: destination)
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        return destination
    }

    private func inspectDependencies() -> InspectDependencies {
        InspectDependencies(
            fileSystem: LiveInspectFileSystem(),
            environment: ProcessInfo.processInfo.environment,
            tools: nil,
            resolveTools: false,
            currentDirectory: temp.path,
            executablePath: nil,
            native: nil,
            mountReader: LiveMountedVolumeReader(),
            resolveNative: true,
            installSignalTrap: true,
            mountPointRoot: temp.path
        )
    }

    private func copyDependencies() -> CopyDependencies {
        CopyDependencies(
            fileSystem: LiveCopyFileSystem(),
            environment: ProcessInfo.processInfo.environment,
            tools: nil,
            resolveTools: false,
            currentDirectory: temp.path,
            now: Date.init,
            chunkSize: 64 * 1024,
            maxBytesOverride: nil,
            chunkObserver: nil,
            executablePath: nil,
            native: nil,
            mountReader: LiveMountedVolumeReader(),
            resolveNative: true,
            installSignalTrap: true,
            mountPointRoot: temp.path
        )
    }

    private func json(_ result: CLIResult) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    private func jsonFile(_ path: String) throws -> [String: Any] {
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

    private func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func assertNothingLeftAttached(_ label: String) {
        let resolved = URL(fileURLWithPath: temp.path).resolvingSymlinksInPath().path
        // DiskImages and DiskArbitration can take a moment to publish a detach.
        // The invariant is "nothing after the run", so poll briefly rather than
        // racing the framework's own cleanup.
        func clean() -> Bool {
            let images = run("/usr/bin/hdiutil", ["info"])
            let mounts = run("/sbin/mount", [])
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temp.path))?
                .filter { $0.hasPrefix("disktriage-mount-") } ?? []
            return !images.contains(temp.path)
                && !images.contains(resolved)
                && !mounts.contains(temp.path)
                && !mounts.contains(resolved)
                && leftovers.isEmpty
        }
        let deadline = Date().addingTimeInterval(3)
        while !clean() && Date() < deadline {
            usleep(50_000)
        }
        let images = run("/usr/bin/hdiutil", ["info"])
        let mounts = run("/sbin/mount", [])
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temp.path))?
            .filter { $0.hasPrefix("disktriage-mount-") } ?? []
        #expect(!images.contains(temp.path), "\(label): no image from this test is still attached")
        #expect(!images.contains(resolved), "\(label): no resolved image path is still attached")
        #expect(!mounts.contains(temp.path), "\(label): no mountpoint from this test is still mounted")
        #expect(!mounts.contains(resolved), "\(label): no resolved mountpoint is still mounted")
        #expect(leftovers.isEmpty, "\(label): no mountpoint directory is left: \(leftovers)")
    }

    // REQ-0306, REQ-0307, REQ-0286
    @Test(
        "REQ0306_REQ0307_REQ0286 live: bare exFAT and whole-disk HFS+ are inspected read-only",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0306_REQ0307_REQ0286_liveInspectsExfatAndHFS() throws {
        let exfat = try copyFixture("exfat-part.img")
        let before = try sha256(exfat)
        let bare = runInspect(arguments: [exfat, "--json"], dependencies: inspectDependencies())
        #expect(bare.exitCode == 0, "\(bare.stdout) \(bare.stderr)")
        let bareObject = try json(bare)
        #expect(bareObject["filesystem"] as? String == "exfat")
        let bareVolumes = try #require(bareObject["volumes"] as? [[String: Any]])
        #expect(bareVolumes.count == 1)
        #expect(bareVolumes[0]["status"] as? String == "ok")
        #expect((bareVolumes[0]["recursive_entries"] as? Int ?? 0) > 0)
        #expect(try sha256(exfat) == before, "the image was never written")
        assertNothingLeftAttached("exfat inspect")

        let hfs = try copyFixture("hfs-disk.dmg")
        let whole = runInspect(arguments: [hfs, "--json"], dependencies: inspectDependencies())
        #expect(whole.exitCode == 0, "\(whole.stdout) \(whole.stderr)")
        let wholeObject = try json(whole)
        #expect(wholeObject["filesystem"] as? String == "hfs+")
        let layout = try #require(wholeObject["layout"] as? [String: Any])
        #expect(layout["kind"] as? String == "whole-disk")
        assertNothingLeftAttached("hfs inspect")
    }

    // REQ-0308
    @Test(
        "REQ0308 live: a bare FAT image is inspected",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0308_liveInspectsFAT() throws {
        let fat = try copyFixture("fat-part.img")
        let result = runInspect(arguments: [fat, "--json"], dependencies: inspectDependencies())
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(try json(result)["filesystem"] as? String == "fat")
        assertNothingLeftAttached("fat inspect")
    }

    // REQ-0287, REQ-0305
    @Test(
        "REQ0287_REQ0305 live: an APFS container lists both volumes",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0287_REQ0305_liveAPFSListsTwoVolumes() throws {
        let apfs = try copyFixture("apfs-disk.img")
        let result = runInspect(arguments: [apfs, "--json"], dependencies: inspectDependencies())
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        let object = try json(result)
        #expect(object["filesystem"] as? String == "apfs")
        let volumes = try #require(object["volumes"] as? [[String: Any]])
        #expect(volumes.count == 2)
        #expect(Set(volumes.compactMap { $0["name"] as? String }) == ["DTAPFS1", "DTAPFS2"])
        assertNothingLeftAttached("apfs inspect")
    }

    // REQ-0288, REQ-0289
    @Test(
        "REQ0288_REQ0289 live: copy requires --volume and selects the second APFS volume",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0288_REQ0289_liveAPFSCopySelectsVolume() throws {
        let apfs = try copyFixture("apfs-disk.img")
        let refused = runCopy(
            arguments: [apfs, "--to", temp.child("apfs-no-volume")],
            dependencies: copyDependencies()
        )
        #expect(refused.exitCode == 30, "\(refused.stdout) \(refused.stderr)")
        #expect(refused.stderr.contains("--volume"))
        assertNothingLeftAttached("apfs refused")

        let destination = temp.child("apfs-volume-two")
        let copied = runCopy(
            arguments: [apfs, "--to", destination, "--volume", "DTAPFS2"],
            dependencies: copyDependencies()
        )
        #expect(copied.exitCode == 0, "\(copied.stdout) \(copied.stderr)")
        #expect(FileManager.default.fileExists(atPath: destination + "/second/only-on-two.txt"))
        let manifest = try jsonFile(destination + "/MANIFEST.json")
        let volume = try #require(manifest["attribution"] as? [String: Any])
        #expect(volume["kind"] as? String == "none")
        assertNothingLeftAttached("apfs copy")
    }

    // REQ-0283, REQ-0284
    @Test(
        "REQ0283_REQ0284 live: a locked encrypted APFS volume is refused without a prompt",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0283_REQ0284_liveEncryptedIsRefused() throws {
        let encrypted = try copyFixture("encrypted-apfs.img")
        let result = runInspect(arguments: [encrypted], dependencies: inspectDependencies())
        #expect(result.exitCode == 30, "\(result.stdout) \(result.stderr)")
        #expect(result.stderr.contains("encrypted and locked"))
        #expect(result.stderr.contains("never prompts for a passphrase"))
        assertNothingLeftAttached("encrypted inspect")
    }

    // REQ-0279, REQ-0281
    @Test(
        "REQ0279_REQ0281 live: a mapfile reports volume-level damage for inspect and copy",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0279_REQ0281_liveMapfileDamage() throws {
        let damaged = try copyFixture("damaged-exfat-part.img")
        let mapfile = try #require(TestFixtures.nativeFixture("damaged-exfat-part.mapfile"))
        try FileManager.default.copyItem(atPath: mapfile, toPath: damaged + ".mapfile")

        let inspected = runInspect(arguments: [damaged, "--json"], dependencies: inspectDependencies())
        #expect(inspected.exitCode == 1, "\(inspected.stdout) \(inspected.stderr)")
        let inspectedObject = try json(inspected)
        let damage = try #require(inspectedObject["damage"] as? [String: Any])
        #expect(damage["status"] as? String == "ok")
        #expect(damage["unreadable_extents"] as? Int == 1)
        assertNothingLeftAttached("damaged inspect")

        let destination = temp.child("damaged-copy")
        let copied = runCopy(arguments: [damaged, "--to", destination], dependencies: copyDependencies())
        #expect(copied.exitCode == 1, "\(copied.stdout) \(copied.stderr)")
        let manifest = try jsonFile(destination + "/MANIFEST.json")
        let manifestDamage = try #require(manifest["damage"] as? [String: Any])
        #expect(manifestDamage["scope"] as? String == "volume")
        #expect(manifestDamage["unreadable_extents"] as? Int == 1)
        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "none")
        assertNothingLeftAttached("damaged copy")
    }

    // REQ-0303, REQ-0304, REQ-0298
    @Test(
        "REQ0303_REQ0304_REQ0298 live: a bare exFAT volume copies with hashes and is never written",
        .enabled(if: TestFixtures.nativeFixtureDirectory() != nil, "native fixtures not built (scripts/bootstrap.sh)")
    )
    func REQ0303_REQ0304_REQ0298_liveCopiesExfat() throws {
        let exfat = try copyFixture("exfat-part.img")
        let before = try sha256(exfat)
        let destination = temp.child("exfat-copy")
        let result = runCopy(arguments: [exfat, "--to", destination], dependencies: copyDependencies())
        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")

        let manifest = try jsonFile(destination + "/MANIFEST.json")
        let files = try #require(manifest["files"] as? [[String: Any]])
        let payload = try #require(files.first { $0["path"] as? String == "media/payload.bin" })
        #expect(payload["status"] as? String == "ok")
        #expect(payload["sha256_read"] as? String == payload["sha256_written"] as? String)
        let readHash = try #require(payload["sha256_read"] as? String)
        #expect(try sha256(destination + "/media/payload.bin") == readHash)
        #expect(try sha256(exfat) == before, "the image was never written")
        assertNothingLeftAttached("exfat copy")
    }
}
