import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCLI
import DiskTriageCollectors

/// One live integration test: the spike's damaged `clip.dat` image and its
/// mapfile, copied through the shipped ntfs-3g runner. The bad extent is a
/// 64 KiB hole at cluster 8735, inside `/media/clip.dat`'s run 8725-8788.
///
/// It runs only when the built prefix and the spike image are present. When
/// either is absent it is reported as **skipped**, never as a pass;
/// `scripts/check.sh` answers 3 for a JUnit `<skipped>` case.
struct CopyLiveTests {
    private let temp = TempDir()


    @Test(
        "live: the spike's damaged image names clip.dat and leaves readme.txt intact",
        .enabled(
            if: liveCopyFixture() != nil,
            "ntfs-3g tools or the spike's damaged-clip-part image not available"
        )
    )
    func REQ0140_liveCopyAttributesTheDamagedFile() throws {
        let fixture = try #require(liveCopyFixture())
        let destination = temp.child("copy-live")

        let before = try sha256(path: fixture.image)
        var environment = ProcessInfo.processInfo.environment
        environment["DISKTRIAGE_NTFS_PREFIX"] = fixture.prefix

        let result = run(
            arguments: [
                "copy", fixture.image,
                "--to", destination,
                "--mapfile", fixture.mapfile,
            ],
            copyDependencies: CopyDependencies.live(environment: environment)
        )

        #expect(result.exitCode == 1, "the mapfile reports damage: \(result.stdout) \(result.stderr)")

        let manifest = try json(destination + "/MANIFEST.json")
        let damage = try #require(manifest["damage"] as? [String: Any])
        #expect(damage["scope"] as? String == "volume")
        #expect(damage["unreadable_extents"] as? Int == 1)
        #expect(damage["unreadable_bytes"] as? Int64 == 65_536)

        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "ntfscluster")

        let files = try #require(manifest["files"] as? [[String: Any]])
        let clip = try #require(files.first { $0["path"] as? String == "media/clip.dat" })
        #expect(clip["integrity"] as? String == "overlaps-bad-extent",
                "the bad extent at cluster 8735 is inside clip.dat's run 8725-8788")

        let readme = try #require(files.first { $0["path"] as? String == "docs/readme.txt" })
        #expect(readme["integrity"] as? String == "intact")
        #expect(readme["status"] as? String == "ok")

        let copy = try #require(manifest["copy"] as? [String: Any])
        #expect(copy["hashes_agree"] as? Bool == true)
        #expect((copy["files_copied"] as? Int ?? 0) > 30, "the whole tree was copied")

        #expect(FileManager.default.fileExists(atPath: destination + "/media/clip.dat"))
        #expect(FileManager.default.fileExists(atPath: destination + "/docs/readme.txt"))
        #expect(try sha256(path: fixture.image) == before, "the image was never written")
    }

    // REQ-0143: an 8 MiB spike file is streamed in 64 KiB chunks, so the file
    // crosses many chunk boundaries and still hashes and copies byte for byte.
    @Test(
        "live: a file larger than one stream chunk is copied by the streaming path",
        .enabled(
            if: liveCopyFixture() != nil,
            "ntfs-3g tools or the spike's damaged-clip-part image not available"
        )
    )
    func REQ0143_liveStreamsAFileLargerThanItsChunk() throws {
        let fixture = try #require(liveCopyFixture())
        let destination = temp.child("copy-live-stream")

        var environment = ProcessInfo.processInfo.environment
        environment["DISKTRIAGE_NTFS_PREFIX"] = fixture.prefix
        var dependencies = CopyDependencies.live(environment: environment)
        dependencies.chunkSize = 64 * 1024

        let result = run(
            arguments: [
                "copy", fixture.image,
                "--to", destination,
                "--mapfile", fixture.mapfile,
            ],
            copyDependencies: dependencies
        )
        #expect(result.exitCode == 1, "the mapfile reports damage: \(result.stdout) \(result.stderr)")

        let manifest = try json(destination + "/MANIFEST.json")
        let files = try #require(manifest["files"] as? [[String: Any]])
        let big = try #require(files.first { $0["path"] as? String == "media/big.bin" })
        #expect(big["status"] as? String == "ok", "big.bin is 8 MiB, well past one 64 KiB chunk")
        #expect(big["size_bytes"] as? Int64 == 8_388_608)
        #expect(big["sha256_read"] as? String == big["sha256_written"] as? String)

        let copied = destination + "/media/big.bin"
        #expect(FileManager.default.fileExists(atPath: copied))
        #expect(try sha256(path: copied) == big["sha256_read"] as? String)
    }

    // MARK: - Support

    private func json(_ path: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any]
        )
    }

    private func sha256(path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Availability

/// The spike's damaged image is gitignored, so it is looked up in the checkout
/// or the main repository beside a linked worktree, exactly like the prefix.
func liveCopyFixture() -> (prefix: String, image: String, mapfile: String)? {
    guard let prefix = liveNTFSPrefix() else { return nil }
    for root in candidateRepositoryRoots() {
        let directory = root + "/captures/ntfs-spike/img"
        let image = directory + "/damaged-clip-part.img"
        let mapfile = directory + "/damaged-clip-part.mapfile"
        if FileManager.default.fileExists(atPath: image),
           FileManager.default.fileExists(atPath: mapfile) {
            return (prefix, image, mapfile)
        }
    }
    return nil
}
