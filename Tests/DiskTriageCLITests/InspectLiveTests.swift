import Foundation
import CryptoKit
import Testing
import DiskTriageCLI
import DiskTriageCollectors

/// One live integration test: a tiny NTFS image built with `mkntfs`, inspected
/// through the shipped ntfs-3g runner. It runs only when a built prefix with
/// `bin/ntfsinfo`, `bin/ntfsls` and `sbin/mkntfs` is available — the spike tree
/// beside the checkout, or `DISKTRIAGE_NTFS_PREFIX`.
///
/// When the tools are absent the test is reported as **skipped**, never as a
/// pass. `scripts/check.sh` answers 3 (UNVERIFIABLE) for a JUnit `<skipped>`
/// case and names the skipped test, so a tool-less host greys the gate rather
/// than passing or failing it; that is a gate property recorded in
/// docs/sdlc.md, not a hidden pass.
struct InspectLiveTests {

    @Test(
        "live: a mkntfs image is inspected read-only, bare and whole-disk",
        .enabled(
            if: liveNTFSPrefix() != nil,
            "ntfs-3g tools and mkntfs not available (set DISKTRIAGE_NTFS_PREFIX)"
        )
    )
    func liveInspection() throws {
        let prefix = try #require(liveNTFSPrefix())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("disktriage-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let volumePath = directory.appendingPathComponent("volume.img").path
        try makeSparseFile(path: volumePath, bytes: 16 * 1_048_576)
        try runMKNTFS(prefix: prefix, image: volumePath)

        let volumeHash = try sha256(path: volumePath)

        // Bare volume: the tools read the image itself.
        let bare = run(
            arguments: ["inspect", volumePath, "--json"],
            inspectDependencies: InspectDependencies.live(environment: liveEnvironment(prefix: prefix))
        )
        #expect(bare.exitCode == 0, "bare: \(bare.stdout) \(bare.stderr)")
        let bareObject = try jsonObject(bare)
        #expect(bareObject["filesystem"] as? String == "ntfs")
        let bareLayout = try #require(bareObject["layout"] as? [String: Any])
        #expect(bareLayout["kind"] as? String == "bare-volume")
        let bareVolume = try #require(bareObject["volume"] as? [String: Any])
        #expect(bareVolume["status"] as? String == "ok")
        #expect(bareVolume["cluster_size"] as? Int == 4096)
        let bareDamage = try #require(bareObject["damage"] as? [String: Any])
        #expect(bareDamage["status"] as? String == "unsupported", "no mapfile: unknown damage")
        #expect(try sha256(path: volumePath) == volumeHash, "the source image was not written")

        // Whole-disk: the same volume inside an MBR at LBA 2048. The tools get
        // an extract, because ntfs-3g has no offset option.
        let diskPath = directory.appendingPathComponent("disk.img").path
        let volumeBytes = try Data(contentsOf: URL(fileURLWithPath: volumePath))
        let partitionStart = 1_048_576
        let partitionSectors = volumeBytes.count / 512
        var disk = [UInt8](repeating: 0, count: partitionStart + volumeBytes.count + 1_048_576)
        disk[446 + 4] = 0x07
        putLE32(&disk, at: 446 + 8, value: UInt32(partitionStart / 512))
        putLE32(&disk, at: 446 + 12, value: UInt32(partitionSectors))
        disk[510] = 0x55
        disk[511] = 0xAA
        disk.replaceSubrange(partitionStart..<(partitionStart + volumeBytes.count), with: volumeBytes)
        try Data(disk).write(to: URL(fileURLWithPath: diskPath))
        let diskHash = try sha256(path: diskPath)

        let whole = run(
            arguments: ["inspect", diskPath, "--json"],
            inspectDependencies: InspectDependencies.live(environment: liveEnvironment(prefix: prefix))
        )
        #expect(whole.exitCode == 0, "whole-disk: \(whole.stdout) \(whole.stderr)")
        let wholeObject = try jsonObject(whole)
        let wholeLayout = try #require(wholeObject["layout"] as? [String: Any])
        #expect(wholeLayout["kind"] as? String == "whole-disk")
        #expect(wholeLayout["scheme"] as? String == "mbr")
        #expect(wholeLayout["offset_bytes"] as? Int == partitionStart)
        #expect(wholeLayout["partition"] as? Int == 1)
        #expect(try sha256(path: diskPath) == diskHash, "the whole-disk image was not written")
    }

    // MARK: - Support

    private func jsonObject(_ result: CLIResult) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    private func liveEnvironment(prefix: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DISKTRIAGE_NTFS_PREFIX"] = prefix
        return environment
    }

    private func makeSparseFile(path: String, bytes: Int) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    private func runMKNTFS(prefix: String, image: String) throws {
        let executable = prefix + "/sbin/mkntfs"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-F", "-Q", "-q", image]
        let null = FileHandle.nullDevice
        process.standardOutput = null
        process.standardError = null
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "mkntfs exited \(process.terminationStatus)")
    }

    private func sha256(path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func putLE32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
}

// MARK: - Availability

/// A built ntfs-3g prefix with the two read tools and `mkntfs`.
func liveNTFSPrefix() -> String? {
    let environment = ProcessInfo.processInfo.environment
    if let prefix = environment["DISKTRIAGE_NTFS_PREFIX"], hasLiveTools(prefix) {
        return prefix
    }
    if let info = NTFSToolLocator.resolve("ntfsinfo", environment: environment) {
        let prefix = URL(fileURLWithPath: info)
            .deletingLastPathComponent()   // bin
            .deletingLastPathComponent()   // prefix
            .path
        if hasLiveTools(prefix) { return prefix }
    }
    for root in candidateRepositoryRoots() {
        let prefix = root + "/captures/ntfs-spike/prefix"
        if hasLiveTools(prefix) { return prefix }
    }
    return nil
}

private func hasLiveTools(_ prefix: String) -> Bool {
    ["bin/ntfsinfo", "bin/ntfsls", "sbin/mkntfs"].allSatisfy {
        FileManager.default.isExecutableFile(atPath: prefix + "/" + $0)
    }
}

/// The checkout and, when this is a linked worktree, the main repository whose
/// gitignored `captures/` holds the spike build.
func candidateRepositoryRoots() -> [String] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCLITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .path
    var roots = [root]

    // A worktree's `.git` is a file: `gitdir: <main>/.git/worktrees/<name>`.
    if let git = try? String(contentsOfFile: root + "/.git", encoding: .utf8),
       git.hasPrefix("gitdir: ") {
        let gitdir = git.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let main = URL(fileURLWithPath: gitdir)
            .deletingLastPathComponent()   // worktrees
            .deletingLastPathComponent()   // .git
            .deletingLastPathComponent()   // main repository
            .path
        if main != root { roots.append(main) }
    }
    return roots
}
