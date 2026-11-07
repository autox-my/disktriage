import Foundation
import CryptoKit
import Testing
import DiskTriageTestSupport
import DiskTriageCollectors
import DiskTriageCore
import DiskTriageCLI

/// `disktriage copy` through the injected ntfs-3g runner and the real local
/// filesystem in a temporary directory. No image is a device and no tool runs;
/// the fixtures are real ntfs-3g output recorded from the spike's small image.
struct CopyCommandTests {
    private let temp = TempDir()


    private static func fixture(_ name: String) throws -> String {
        try String(contentsOfFile: fixturePath(name), encoding: .utf8)
    }

    private static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: fixturePath(name)))
    }

    /// The small image's `ntfsinfo -m`, `ntfsls -l -R` and `ntfscluster -v`.
    /// `/payload.bin` is the only file with a non-resident run (LCN 2560-2591).
    private static func workingTools(
        files: [String: Data]? = nil,
        recorder: ToolImageRecorder? = nil
    ) throws -> ScriptedCopyTools {
        let contents: [String: Data]
        if let files {
            contents = files
        } else {
            contents = [
                "/readme.txt": try fixtureData("ntfscat-copy-readme.bin"),
                "/docs/notes.md": try fixtureData("ntfscat-copy-notes.bin"),
                "/docs/leaf.dat": try fixtureData("ntfscat-copy-leaf.bin"),
                "/payload.bin": try fixtureData("ntfscat-copy-payload.bin"),
                "/docs/payload.bin": try fixtureData("ntfscat-copy-docs-payload.bin"),
            ]
        }
        var onImage: (@Sendable (String) -> Void)?
        if let recorder {
            onImage = { path in recorder.record(path) }
        }
        return ScriptedCopyTools(
            volume: .ok(try fixture("ntfsinfo-copy.txt")),
            listing: .ok(try fixture("ntfsls-copy.txt")),
            cluster: .ok(try fixture("ntfscluster-copy.txt")),
            files: contents,
            onImage: onImage
        )
    }

    private static let payloadSHA = "9da12ab2cd07bf7997023836be0e1e05fcc54ef9849c2b897795fa351d941672"
    private static let docsPayloadSHA = "f1dd9c7ee8025b3677abcc48286dddfb54f20ad24fc220090c1e2feebda32e50"
    private static let readmeSHA = "9544a59f0b48642d42bb8c6c48f59647f9cf572c00af0cf16c70e19d0247165f"
    private static let notesSHA = "a3b9f29e960425c6f46de477a354301633a4336b4ad3b5795143152fbf0f12d6"

    // REQ-0128 / REQ-0136: a damaged mapfile is copied with a manifest, and the
    // file whose run intersects the bad cluster is named.
    @Test("REQ0128_REQ0136 copy hashes every file, writes a manifest, and names the damaged file")
    func REQ0128_REQ0134_REQ0136_copiesAndAttributes() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let mapfile = try writeMapfile(at: image)

        let result = runCopy(
            arguments: [image, "--to", destination, "--mapfile", mapfile],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )

        #expect(result.exitCode == 1, "copied, but the mapfile reports damage: \(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("written == read"), "\(result.stdout)")
        #expect(result.stdout.contains("damage reported"), "\(result.stdout)")

        // The tree is preserved byte for byte.
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/readme.txt"))
            == (try Self.fixtureData("ntfscat-copy-readme.bin")))
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/docs/payload.bin"))
            == (try Self.fixtureData("ntfscat-copy-docs-payload.bin")))
        #expect(FileManager.default.fileExists(atPath: destination + "/MANIFEST.json"))
        #expect(FileManager.default.fileExists(atPath: destination + "/SUMMARY.txt"))

        let manifest = try json(destination + "/MANIFEST.json")
        #expect(manifest["schema"] as? String == "disktriage.copy/1")
        #expect(manifest["image_sha256"] is NSNull, "hashing the image is off by default")
        #expect((manifest["image_sha256_note"] as? String)?.contains("--hash-image") == true)

        let damage = try #require(manifest["damage"] as? [String: Any])
        #expect(damage["scope"] as? String == "volume")
        #expect(damage["status"] as? String == "ok")
        #expect(damage["unreadable_extents"] as? Int == 1)
        #expect(damage["unreadable_bytes"] as? Int64 == 4096)

        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "ntfscluster")

        let files = try #require(manifest["files"] as? [[String: Any]])
        let payload = try #require(files.first { $0["path"] as? String == "payload.bin" })
        #expect(payload["integrity"] as? String == "overlaps-bad-extent")
        #expect(payload["attribution"] as? String == "ntfscluster")
        #expect(payload["sha256_read"] as? String == Self.payloadSHA,
                "the read hash is the fixture's hash, not recomputed from the tool")
        #expect(payload["sha256_written"] as? String == Self.payloadSHA)

        let docsPayload = try #require(files.first { $0["path"] as? String == "docs/payload.bin" })
        #expect(docsPayload["integrity"] as? String == "intact",
                "the next file's run (2592-2596) does not overlap cluster 2560")
        #expect(docsPayload["sha256_read"] as? String == Self.docsPayloadSHA)

        let readme = try #require(files.first { $0["path"] as? String == "readme.txt" })
        #expect(readme["integrity"] as? String == "intact")
        #expect(readme["sha256_read"] as? String == Self.readmeSHA)

        let copy = try #require(manifest["copy"] as? [String: Any])
        #expect(copy["hashes_agree"] as? Bool == true)
        #expect(copy["files_copied"] as? Int == 5)
    }

    // REQ-0172: the same failed-versus-bad accounting reaches copy's damage
    // section; an incomplete mapfile still means no per-file claim.
    @Test("REQ0172 copy reports failed extents as unreadable and claims no per-file integrity")
    func REQ0172_REQ0177_copyCountsFailedExtentsAsUnreadable() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        try Data(try Self.fixture("minah-partial-me.mapfile.txt").utf8)
            .write(to: URL(fileURLWithPath: image + ".mapfile"))

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        #expect(result.exitCode == 1, "\(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("12 unreadable extents"), "\(result.stdout)")
        #expect(result.stdout.contains("may shrink after trimming"), "\(result.stdout)")

        let manifest = try json(destination + "/MANIFEST.json")
        let damage = try #require(manifest["damage"] as? [String: Any])
        #expect(damage["unreadable_extents"] as? Int == 12)
        #expect(damage["unreadable_bytes"] as? Int == 786_432)
        #expect(damage["failed_extents"] as? Int == 12)
        #expect(damage["failed_bytes"] as? Int == 786_432)
        #expect(damage["bad_extents"] as? Int == 0)
        #expect(damage["bad_bytes"] as? Int == 0)

        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "none",
                "an incomplete mapfile makes the damage extent unknown")
        #expect((attribution["reason"] as? String)?.contains("not rescued") == true)
    }

    // REQ-0125: copy takes an image file, never a device node.
    @Test("REQ0125 copy refuses a device node and a symlink to one")
    func REQ0125_refusesADeviceNode() throws {
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let direct = runCopy(
            arguments: ["/dev/null", "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        #expect(direct.exitCode == 2, "a device node is a usage error, not a tool error")
        #expect(direct.stderr.contains("/dev"))
        #expect(direct.stderr.contains("image"))

        let directory = temp.child("copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let link = directory + "/ordinary.img"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/dev/null")
        let symlink = runCopy(
            arguments: [link, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        #expect(symlink.exitCode == 2)
        #expect(symlink.stderr.contains("/dev/null"))
    }

    // REQ-0142: a cap makes the copy partial, never a silent short tree.
    @Test("REQ0142 a file above the per-file cap makes the copy partial")
    func REQ0142_capsMakeTheCopyPartial() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        // 3 TiB is above the 2 TiB per-file sanity bound. The cap is no longer
        // a memory bound, so the fixture must exceed the new value.
        let listing = """
        /:
         3298534883328 Nov  7 09:31 2026 huge.bin

        """
        var tools = try Self.workingTools()
        tools.listing = .ok(listing)

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: tools)
        )

        #expect(result.exitCode == 1, "a cap is not a clean copy: \(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("per-file cap"))
        let manifest = try json(destination + "/MANIFEST.json")
        let copy = try #require(manifest["copy"] as? [String: Any])
        #expect(copy["status"] as? String == "partial")
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.first?["status"] as? String == "skipped")
        #expect(!FileManager.default.fileExists(atPath: destination + "/huge.bin"))
    }

    // REQ-0145: the last partial chunk is hashed, not dropped.
    @Test("REQ0145 the final partial chunk is part of the read hash")
    func REQ0145_hashesTheLastPartialChunk() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let chunks = [
            Data(repeating: 0x41, count: 64),
            Data(repeating: 0x42, count: 64),
            Data(repeating: 0x43, count: 7),
        ]
        let data = chunks.reduce(Data(), +)
        let expected = sha256(data)
        let tools = try streamedTools(
            listing: singleFileListing("partial.bin", size: Int64(data.count)),
            chunks: chunks
        )

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: tools, chunkSize: 64)
        )

        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        let files = try #require(try json(destination + "/MANIFEST.json")["files"] as? [[String: Any]])
        let entry = try #require(files.first)
        #expect(entry["sha256_read"] as? String == expected,
                "the 7-byte final chunk must be hashed: \(expected)")
        #expect(entry["sha256_written"] as? String == expected)
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/partial.bin")) == data)
    }

    // REQ-0143: the copy loop holds one chunk at a time, not the whole file.
    @Test("REQ0143 a streamed file is handled one chunk at a time")
    func REQ0143_holdsOnlyOneChunk() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let chunks = (0..<16).map { value in Data(repeating: UInt8(value), count: 64) }
        let data = chunks.reduce(Data(), +)
        let observer = ChunkPeakObserver()
        let tools = try streamedTools(
            listing: singleFileListing("streamed.bin", size: Int64(data.count)),
            chunks: chunks
        )

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: tools, chunkSize: 64, observer: observer)
        )

        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        #expect(observer.total == chunks.count, "every chunk went through the streaming sink")
        #expect(observer.peak <= 1, "the implementation held \(observer.peak) chunks at once")
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/streamed.bin")) == data)
    }

    // REQ-0144 / REQ-0146: a writer that fails mid-file leaves neither a
    // final file nor its temporary file, and the entry is `incomplete`.
    @Test("REQ0144_REQ0146 a failed writer leaves no final or temporary file")
    func REQ0144_REQ0146_failedWriterLeavesNothing() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let chunks = (0..<8).map { _ in Data(repeating: 0x5A, count: 64) }
        let tools = try streamedTools(
            listing: singleFileListing("big.bin", size: 512),
            chunks: chunks
        )

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(
                tools: tools,
                fileSystem: FailingCopyFileSystem(failAfter: 256),
                chunkSize: 64
            )
        )

        #expect(result.exitCode == 1, "a partial copy is exit 1: \(result.stdout) \(result.stderr)")
        let files = try #require(try json(destination + "/MANIFEST.json")["files"] as? [[String: Any]])
        #expect(files.first?["status"] as? String == "incomplete")
        #expect((files.first?["note"] as? String)?.contains("discarded") == true)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination)
        #expect(!leftovers.contains("big.bin"), "an unfinished file is never installed")
        #expect(!leftovers.contains { $0.contains("disktriage-partial") }, "the temp file was deleted")
    }

    // REQ-0144: the read-back happens before the install, so a corrupting
    // writer never leaves a plausible final file behind.
    @Test("REQ0144 a read-back mismatch is caught before the file is installed")
    func REQ0144_readBackIsCheckedBeforeInstall() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let data = Data(repeating: 0x7E, count: 128)
        let tools = try streamedTools(
            listing: singleFileListing("corrupt.bin", size: Int64(data.count)),
            chunks: [data]
        )

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(
                tools: tools,
                fileSystem: CorruptingCopyFileSystem(),
                chunkSize: 64
            )
        )

        #expect(result.exitCode == 1, "a hash mismatch is not success: \(result.stdout) \(result.stderr)")
        let files = try #require(try json(destination + "/MANIFEST.json")["files"] as? [[String: Any]])
        #expect(files.first?["status"] as? String == "hash-mismatch")
        #expect(!FileManager.default.fileExists(atPath: destination + "/corrupt.bin"),
                "the install must follow the read-back check")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination)
        #expect(!leftovers.contains { $0.contains("disktriage-partial") })
    }

    // REQ-0146: a timeout mid-stream discards the partial file and records the
    // entry as incomplete, never as copied.
    @Test("REQ0146 a timeout mid-stream marks the file incomplete")
    func REQ0146_timeoutMidStreamIsIncomplete() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let chunks = (0..<4).map { _ in Data(repeating: 0x33, count: 64) }
        let tools = try streamedTools(
            listing: singleFileListing("timed-out.bin", size: 4096),
            chunks: chunks,
            outcome: .timeout
        )

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: tools, chunkSize: 64)
        )

        #expect(result.exitCode == 1, "a timeout is a partial copy: \(result.stdout) \(result.stderr)")
        let files = try #require(try json(destination + "/MANIFEST.json")["files"] as? [[String: Any]])
        #expect(files.first?["status"] as? String == "incomplete")
        #expect((files.first?["note"] as? String)?.contains("timeout") == true)
        #expect(!FileManager.default.fileExists(atPath: destination + "/timed-out.bin"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination)
        #expect(!leftovers.contains { $0.contains("disktriage-partial") })
    }

    // REQ-0148: --max-bytes is a run cap; hitting it mid-stream discards the
    // partial file and marks the copy partial.
    @Test("REQ0148 --max-bytes stops a stream and makes the copy partial")
    func REQ0148_maxBytesStopsTheStream() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let chunks = (0..<8).map { _ in Data(repeating: 0x21, count: 64) }
        let tools = try streamedTools(
            listing: singleFileListing("capped.bin", size: 64),
            chunks: chunks
        )

        let result = runCopy(
            arguments: [image, "--to", destination, "--max-bytes", "1"],
            dependencies: copyDependencies(tools: tools, chunkSize: 64, maxBytes: 256)
        )

        #expect(result.exitCode == 1, "a cap is a partial copy: \(result.stdout) \(result.stderr)")
        let manifest = try json(destination + "/MANIFEST.json")
        let copy = try #require(manifest["copy"] as? [String: Any])
        #expect(copy["status"] as? String == "partial")
        #expect(copy["max_bytes"] as? Int64 == 256)
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.first?["status"] as? String == "incomplete")
        #expect((files.first?["note"] as? String)?.contains("--max-bytes cap") == true)
        #expect(!FileManager.default.fileExists(atPath: destination + "/capped.bin"))

        let usage = runCopy(
            arguments: [image, "--to", destination, "--max-bytes", "0"],
            dependencies: copyDependencies(tools: tools)
        )
        #expect(usage.exitCode == 2, "a non-positive --max-bytes is a usage error")
    }

    // REQ-0149: a zero-length file is a real, empty file, not a skipped entry.
    @Test("REQ0149 a zero-length file is copied with the empty-input hash")
    func REQ0149_copiesAZeroLengthFile() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let emptyHash = sha256(Data())
        let tools = try streamedTools(
            listing: singleFileListing("empty.bin", size: 0),
            chunks: []
        )

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: tools, chunkSize: 64)
        )

        #expect(result.exitCode == 0, "\(result.stdout) \(result.stderr)")
        let files = try #require(try json(destination + "/MANIFEST.json")["files"] as? [[String: Any]])
        let entry = try #require(files.first)
        #expect(entry["status"] as? String == "ok")
        #expect(entry["size_bytes"] as? Int64 == 0)
        #expect(entry["sha256_read"] as? String == emptyHash)
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/empty.bin")).isEmpty)
    }

    // REQ-0126: copy never overwrites a destination file.
    @Test("REQ0126 an existing destination file is refused before any write")
    func REQ0126_refusesToOverwrite() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let existing = destination + "/readme.txt"
        try Data("do not overwrite me".utf8).write(to: URL(fileURLWithPath: existing))

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("readme.txt"))
        #expect(result.stderr.contains("never overwrites"))
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "do not overwrite me")
        #expect(!FileManager.default.fileExists(atPath: destination + "/payload.bin"),
                "nothing else was copied either")
    }

    // REQ-0127: a name from the volume never becomes a path outside --to.
    @Test("REQ0127 a '..' component in a listed name is refused")
    func REQ0127_refusesPathTraversal() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let listing = """
        /:
              10 Nov  7 09:31 2026 ../evil.txt

        """
        var tools = try Self.workingTools()
        tools.listing = .ok(listing)

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: tools)
        )

        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("path traversal"))
        #expect(!FileManager.default.fileExists(atPath: destination),
                "the destination is not created for a refused tree")
    }

    // REQ-0128 / mutation (d): the written hash is compared with the read hash.
    @Test("REQ0128 a writer that corrupts bytes is detected as a hash mismatch")
    func REQ0128_detectsACorruptingWriter() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let dependencies = CopyDependencies(
            fileSystem: CorruptingCopyFileSystem(),
            environment: [:],
            tools: try Self.workingTools(),
            resolveTools: false
        )

        let result = runCopy(arguments: [image, "--to", destination], dependencies: dependencies)

        #expect(result.exitCode == 1, "a hash mismatch is not success: \(result.stdout) \(result.stderr)")
        let manifest = try json(destination + "/MANIFEST.json")
        let files = try #require(manifest["files"] as? [[String: Any]])
        let mismatch = try #require(files.first { $0["status"] as? String == "hash-mismatch" })
        #expect((mismatch["sha256_written"] as? String) != (mismatch["sha256_read"] as? String))
        let copy = try #require(manifest["copy"] as? [String: Any])
        #expect(copy["hashes_agree"] as? Bool == false)
        #expect(copy["files_copied"] as? Int == 0, "a hash mismatch is not a faithful copy")
        #expect(copy["files_failed"] as? Int == 5)
    }

    // REQ-0129: the image is only read.
    @Test("REQ0129 copying an image never writes it")
    func REQ0129_imageIsNeverWritten() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let before = try sha256(path: image)
        let mapfile = try writeMapfile(at: image)

        _ = runCopy(
            arguments: [image, "--to", destination, "--mapfile", mapfile],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )

        #expect(try sha256(path: image) == before)
    }

    // REQ-0130 / REQ-0131: no mapfile is unknown damage and no per-file claim.
    @Test("REQ0130_REQ0131 no mapfile leaves damage unknown and makes no per-file claim")
    func REQ0130_REQ0131_REQ0134_noMapfileMakesNoClaim() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )

        #expect(result.exitCode == 0, "unknown is not damage: \(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("damage UNKNOWN"))
        let manifest = try json(destination + "/MANIFEST.json")
        let damage = try #require(manifest["damage"] as? [String: Any])
        #expect(damage["status"] as? String == "unsupported")
        #expect(damage["unreadable_extents"] is NSNull, "absent is null, never zero")

        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "none")
        #expect((attribution["reason"] as? String)?.contains("no mapfile") == true)

        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.allSatisfy { $0["integrity"] == nil },
                "attribution none means no per-file integrity claim")
    }

    // REQ-0131 / mutation (f): a failed ntfscluster pass makes no per-file claim.
    @Test("REQ0131 a failed ntfscluster pass makes no per-file claim on a damaged image")
    func REQ0131_failedAttributionMakesNoClaim() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let mapfile = try writeMapfile(at: image)
        var tools = try Self.workingTools()
        tools.cluster = .timeout()

        let result = runCopy(
            arguments: [image, "--to", destination, "--mapfile", mapfile],
            dependencies: copyDependencies(tools: tools)
        )

        #expect(result.exitCode == 1, "damage with no attribution is not a pass")
        #expect(result.stdout.contains("no per-file integrity claim"))
        let manifest = try json(destination + "/MANIFEST.json")
        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "none")
        #expect((attribution["reason"] as? String)?.contains("120 s") == true)

        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.allSatisfy { $0["integrity"] == nil },
                "never mark every file unknown: make no claim at all")
    }

    // REQ-0131: an incomplete mapfile leaves the damage extent unknown, so the
    // run map cannot support a per-file claim even when it succeeds.
    @Test("REQ0131 an incomplete mapfile makes no per-file claim")
    func REQ0131_incompleteMapfileMakesNoClaim() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let mapfile = image + ".mapfile"
        try Data("""
        # Mapfile. Created by hand for the copy test
        # current_pos  current_status  current_pass
        0x00000000     ?               1
        #      pos        size  status
        0x00000000  0x00080000  +
        0x00080000  0x00080000  ?
        """.utf8).write(to: URL(fileURLWithPath: mapfile))

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )

        #expect(result.exitCode == 1, "not-rescued bytes are not a clean copy")
        #expect(result.stdout.contains("not rescued"))
        let manifest = try json(destination + "/MANIFEST.json")
        let attribution = try #require(manifest["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "none")
        #expect((attribution["reason"] as? String)?.contains("incomplete") == true)
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.allSatisfy { $0["integrity"] == nil })
    }

    // REQ-0135: a whole-disk image extracts the partition and subtracts its
    // offset before converting the mapfile extent to clusters.
    @Test("REQ0135 a whole-disk image is extracted and its partition offset is subtracted")
    func REQ0135_wholeDiskOffsetIsSubtracted() throws {
        let partitionOffset: Int64 = 4096
        let image = try makeWholeDiskImage(partitionOffset: partitionOffset)
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        // Cluster 2560 is 2560 * 4096 bytes into the volume.
        let badPosition = partitionOffset + 2560 * 4096
        let imageSize = partitionOffset + 16 * 1024 * 1024 + 4096
        let mapfile = image + ".mapfile"
        try Data("""
        # Mapfile. Created by hand for the copy test
        # Finished
        # current_pos  current_status  current_pass
        0x00000000     +               1
        #      pos        size  status
        0x00000000  0x\(String(badPosition, radix: 16))  +
        0x\(String(badPosition, radix: 16))  0x00001000  -
        0x\(String(badPosition + 4096, radix: 16))  0x\(String(imageSize - badPosition - 4096, radix: 16))  +
        """.utf8).write(to: URL(fileURLWithPath: mapfile))

        let recorder = ToolImageRecorder()
        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools(recorder: recorder))
        )

        #expect(result.exitCode == 1, "\(result.stdout) \(result.stderr)")
        let manifest = try json(destination + "/MANIFEST.json")
        let files = try #require(manifest["files"] as? [[String: Any]])
        let payload = try #require(files.first { $0["path"] as? String == "payload.bin" })
        #expect(payload["integrity"] as? String == "overlaps-bad-extent",
                "the partition offset must be subtracted before dividing by the cluster size")

        let (paths, firstBytes) = recorder.snapshot
        #expect(paths.allSatisfy { $0 != image }, "the tools never read the whole-disk image")
        #expect(firstBytes.allSatisfy { $0.starts(with: Data([0xEB, 0x52, 0x90])) },
                "the tools read an extract that starts at the partition boot sector")
    }

    // REQ-0136: --json is the same report with stable section keys.
    @Test("REQ0136 --json carries the stable copy, damage and attribution sections")
    func REQ0136_jsonReportHasStableSections() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        let mapfile = try writeMapfile(at: image)

        let result = runCopy(
            arguments: [image, "--to", destination, "--mapfile", mapfile, "--json"],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        #expect(result.exitCode == 1)
        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(report["command"] as? String == "copy")
        #expect(report["status"] as? String == "damage")
        #expect(report["exit_code"] as? Int == 1)
        #expect(report["destination"] as? String == destination)

        let copy = try #require(report["copy"] as? [String: Any])
        #expect(copy["hashes_agree"] as? Bool == true)
        let damage = try #require(report["damage"] as? [String: Any])
        #expect(damage["scope"] as? String == "volume")
        let attribution = try #require(report["attribution"] as? [String: Any])
        #expect(attribution["kind"] as? String == "ntfscluster")
        let files = try #require(report["files"] as? [[String: Any]])
        #expect(files.count == 5)
    }

    // REQ-0132: the manifest states what hash equality proves.
    @Test("REQ0132 the manifest says hash equality is against the image, not the platter")
    func REQ0132_hashEqualityWording() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }
        _ = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        let manifest = try json(destination + "/MANIFEST.json")
        let notes = try #require(manifest["notes"] as? [String])
        #expect(notes.contains { $0.contains("copy matches the IMAGE, not that the image matches the platter") })
    }

    // REQ-0137: --hash-image is optional and recorded; the default is null.
    @Test("REQ0137 --hash-image records the image hash and the default records null")
    func REQ0137_hashImageIsOptional() throws {
        let image = try makeBareNTFSImage()
        let offDestination = temp.child("copy-\(UUID().uuidString)")
        let onDestination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: offDestination)
            try? FileManager.default.removeItem(atPath: onDestination)
        }

        _ = runCopy(
            arguments: [image, "--to", offDestination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        let off = try json(offDestination + "/MANIFEST.json")
        #expect(off["image_sha256"] is NSNull)

        _ = runCopy(
            arguments: [image, "--to", onDestination, "--hash-image"],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        let on = try json(onDestination + "/MANIFEST.json")
        #expect(on["image_sha256"] as? String == (try sha256(path: image)))
    }

    // REQ-0133: non-NTFS filesystems are named and refused, never mounted.
    @Test("REQ0133 a non-NTFS image is refused as not implemented")
    func REQ0133_nonNTFSIsRefused() throws {
        var bytes = [UInt8](repeating: 0, count: 8192)
        bytes.replaceSubrange(32..<36, with: Array("NXSB".utf8))
        let image = try makeFile(bytes)
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: copyDependencies(tools: try Self.workingTools())
        )
        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("apfs"))
        #expect(result.stderr.contains("native read-only attach not implemented yet"))
        #expect(!FileManager.default.fileExists(atPath: destination))
    }

    // REQ-0121-style precondition: missing tools are exit 30 with the hint.
    @Test("missing copy tools exit 30 with the prefix hint")
    func missingToolsExitThirty() throws {
        let image = try makeBareNTFSImage()
        let destination = temp.child("copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: image)
            try? FileManager.default.removeItem(atPath: destination)
        }

        let result = runCopy(
            arguments: [image, "--to", destination],
            dependencies: CopyDependencies(
                fileSystem: LiveCopyFileSystem(),
                environment: ["PATH": "", "DISKTRIAGE_NTFS_PREFIX": ""],
                tools: nil,
                resolveTools: false
            )
        )
        #expect(result.exitCode == 30)
        #expect(result.stderr.contains("DISKTRIAGE_NTFS_PREFIX"))
        #expect(result.stderr.contains("ntfscluster"))
    }

    @Test("copy --help exits 0 and reads nothing")
    func helpExitsZero() {
        let result = runCopy(arguments: ["--help"], dependencies: nil)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("usage: disktriage copy"))
        #expect(result.stderr.isEmpty)
    }

    // MARK: - Support

    private func copyDependencies(
        tools: (any NTFSCopyToolRunning)?,
        fileSystem: any CopyFileSystem = LiveCopyFileSystem(),
        chunkSize: Int = CopyLimits.streamChunkBytes,
        observer: (any CopyChunkObserving)? = nil,
        maxBytes: Int64? = nil
    ) -> CopyDependencies {
        CopyDependencies(
            fileSystem: fileSystem,
            environment: [:],
            tools: tools,
            resolveTools: false,
            now: { Date(timeIntervalSince1970: 1_791_360_000) },
            chunkSize: chunkSize,
            maxBytesOverride: maxBytes,
            chunkObserver: observer
        )
    }

    private func writeMapfile(at image: String) throws -> String {
        let path = image + ".mapfile"
        try Data(try Self.fixture("ntfs-copy-damaged.mapfile.txt").utf8)
            .write(to: URL(fileURLWithPath: path))
        return path
    }

    private func singleFileListing(_ name: String, size: Int64) -> String {
        """
        /:
         \(size) Nov  7 09:31 2026 \(name)

        """
    }

    private func streamedTools(
        listing: String,
        chunks: [Data],
        outcome: CollectOutcome = .ok
    ) throws -> StreamedCopyTools {
        StreamedCopyTools(
            volume: .ok(try Self.fixture("ntfsinfo-copy.txt")),
            listing: .ok(listing),
            cluster: .ok(try Self.fixture("ntfscluster-copy.txt")),
            chunks: chunks,
            outcome: outcome
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A 16 MiB sparse bare NTFS volume: only the boot sector is material.
    private func makeBareNTFSImage(clusters: Int64 = 4096) throws -> String {
        let path = temp.child("disktriage-copy-image-\(UUID().uuidString).img")
        try makeSparseFile(path: path, bytes: clusters * 4096)
        try write(makeBootSector(totalSectors: UInt64(clusters * 8)), to: path, offset: 0)
        return path
    }

    /// A whole-disk image: an MBR at LBA 0, an NTFS partition at `offset`.
    private func makeWholeDiskImage(partitionOffset: Int64) throws -> String {
        let volumeBytes = Int64(16 * 1024 * 1024)
        let path = temp.child("disktriage-copy-disk-\(UUID().uuidString).img")
        try makeSparseFile(path: path, bytes: partitionOffset + volumeBytes + 4096)

        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[446 + 4] = 0x07
        putLE32(&mbr, at: 446 + 8, value: UInt32(partitionOffset / 512))
        putLE32(&mbr, at: 446 + 12, value: UInt32(volumeBytes / 512))
        mbr[510] = 0x55
        mbr[511] = 0xAA
        try write(mbr, to: path, offset: 0)
        try write(makeBootSector(totalSectors: UInt64(volumeBytes / 512)), to: path, offset: partitionOffset)
        return path
    }

    private func makeFile(_ bytes: [UInt8]) throws -> String {
        let path = temp.child("disktriage-copy-\(UUID().uuidString).img")
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeSparseFile(path: String, bytes: Int64) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
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

    private func json(_ path: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any]
        )
    }
}

// MARK: - Scripted tools

private struct ScriptedCopyTools: NTFSCopyToolRunning {
    var volume: CollectorResult = .ok("")
    var listing: CollectorResult = .ok("")
    var cluster: CollectorResult = .ok("")
    var files: [String: Data] = [:]
    var onImage: (@Sendable (String) -> Void)?

    func volumeInfo(image: String) -> CollectorResult {
        onImage?(image)
        return volume
    }

    func listing(image: String) -> CollectorResult {
        onImage?(image)
        return listing
    }

    func catFile(image: String, path: String) -> CommandDataResult {
        onImage?(image)
        return .ok(files[path] ?? Data())
    }

    func clusterRuns(image: String, lastCluster: Int64) -> CollectorResult {
        onImage?(image)
        return cluster
    }
}

// MARK: - Corrupting writer

/// Passes every read through to the real filesystem but flips the first byte of
/// every write, so the read-back hash must disagree.
private struct CorruptingCopyFileSystem: CopyFileSystem {
    private let base = LiveCopyFileSystem()

    func exists(_ path: String) -> Bool { base.exists(path) }
    func isRegularFile(_ path: String) -> Bool { base.isRegularFile(path) }
    func isDirectory(_ path: String) -> Bool { base.isDirectory(path) }
    func size(_ path: String) throws -> Int64 { try base.size(path) }
    func read(_ path: String, offset: Int64, count: Int) throws -> Data {
        try base.read(path, offset: offset, count: count)
    }
    func extract(from source: String, offset: Int64, length: Int64, to destination: String) throws -> Int64 {
        try base.extract(from: source, offset: offset, length: length, to: destination)
    }
    func copy(from source: String, to destination: String) throws {
        try base.copy(from: source, to: destination)
    }
    func write(_ data: Data, to path: String, offset: Int64) throws {
        try base.write(data, to: path, offset: offset)
    }
    func remove(_ path: String) { base.remove(path) }
    func temporaryFile() -> String { base.temporaryFile() }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }

    func writeFile(_ data: Data, to path: String) throws {
        var corrupt = data
        // The manifest and summary are the command's own records, not copied
        // file data; corrupting them would hide the mismatch behind bad JSON.
        let isReserved = path.hasSuffix("/MANIFEST.json") || path.hasSuffix("/SUMMARY.txt")
        if !isReserved, !corrupt.isEmpty { corrupt[0] ^= 0xFF }
        try base.writeFile(corrupt, to: path)
    }

    func makeWriter(to path: String) throws -> any CopyFileWriter {
        CorruptingCopyWriter(base: try base.makeWriter(to: path))
    }

    @discardableResult
    func readChunks(
        _ path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) throws -> Int64 {
        try base.readChunks(path, chunkSize: chunkSize, consume: consume)
    }
}

/// Corrupts the first byte of every chunk it is asked to write, so the
/// read-back hash must disagree.
private final class CorruptingCopyWriter: CopyFileWriter {
    private let base: any CopyFileWriter

    init(base: any CopyFileWriter) {
        self.base = base
    }

    var temporaryPath: String { base.temporaryPath }

    func write(_ data: Data) throws {
        var corrupt = data
        if !corrupt.isEmpty { corrupt[0] ^= 0xFF }
        try base.write(corrupt)
    }

    func sync() throws { try base.sync() }
    func commit() throws { try base.commit() }
    func abort() { base.abort() }
}

// MARK: - Streamed chunks

/// Yields its chunks through the streaming seam. `outcome` is returned after
/// the last chunk, so `.timeout` models a child that stopped mid-stream.
private final class StreamedCopyTools: NTFSCopyToolRunning, @unchecked Sendable {
    let volume: CollectorResult
    let listing: CollectorResult
    let cluster: CollectorResult
    let chunks: [Data]
    let outcome: CollectOutcome

    init(
        volume: CollectorResult,
        listing: CollectorResult,
        cluster: CollectorResult,
        chunks: [Data],
        outcome: CollectOutcome = .ok
    ) {
        self.volume = volume
        self.listing = listing
        self.cluster = cluster
        self.chunks = chunks
        self.outcome = outcome
    }

    func volumeInfo(image: String) -> CollectorResult { volume }
    func listing(image: String) -> CollectorResult { listing }
    func clusterRuns(image: String, lastCluster: Int64) -> CollectorResult { cluster }

    func catFile(image: String, path: String) -> CommandDataResult {
        .ok(chunks.reduce(Data(), +))
    }

    func catFileStreaming(
        image: String,
        path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) -> CommandStreamResult {
        var bytes: Int64 = 0
        for chunk in chunks {
            do {
                try consume(chunk)
                bytes += Int64(chunk.count)
            } catch {
                return CommandStreamResult(
                    outcome: .error,
                    exitCode: 0,
                    bytesRead: bytes,
                    consumerFailed: true,
                    consumerError: String(describing: error)
                )
            }
        }
        return CommandStreamResult(
            outcome: outcome,
            exitCode: outcome == .ok ? 0 : 1,
            bytesRead: bytes
        )
    }
}

/// Counts how many chunks the copy loop holds at once. The streaming loop
/// acquires and releases one chunk at a time; a buffering implementation
/// raises `peak` to the whole file.
private final class ChunkPeakObserver: CopyChunkObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var peakValue = 0
    private var totalValue = 0

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalValue
    }

    func chunkAcquired() {
        lock.lock()
        live += 1
        totalValue += 1
        peakValue = max(peakValue, live)
        lock.unlock()
    }

    func chunkReleased() {
        lock.lock()
        live -= 1
        lock.unlock()
    }
}

/// Delegates every read to the live filesystem, but its writer throws once the
/// file would pass `failAfter` bytes.
private struct FailingCopyFileSystem: CopyFileSystem {
    let failAfter: Int
    private let base = LiveCopyFileSystem()

    func exists(_ path: String) -> Bool { base.exists(path) }
    func isRegularFile(_ path: String) -> Bool { base.isRegularFile(path) }
    func isDirectory(_ path: String) -> Bool { base.isDirectory(path) }
    func size(_ path: String) throws -> Int64 { try base.size(path) }
    func read(_ path: String, offset: Int64, count: Int) throws -> Data {
        try base.read(path, offset: offset, count: count)
    }
    func extract(from source: String, offset: Int64, length: Int64, to destination: String) throws -> Int64 {
        try base.extract(from: source, offset: offset, length: length, to: destination)
    }
    func copy(from source: String, to destination: String) throws {
        try base.copy(from: source, to: destination)
    }
    func write(_ data: Data, to path: String, offset: Int64) throws {
        try base.write(data, to: path, offset: offset)
    }
    func remove(_ path: String) { base.remove(path) }
    func temporaryFile() -> String { base.temporaryFile() }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func writeFile(_ data: Data, to path: String) throws { try base.writeFile(data, to: path) }

    func makeWriter(to path: String) throws -> any CopyFileWriter {
        FailingCopyWriter(base: try base.makeWriter(to: path), failAfter: failAfter)
    }

    @discardableResult
    func readChunks(
        _ path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) throws -> Int64 {
        try base.readChunks(path, chunkSize: chunkSize, consume: consume)
    }
}

private final class FailingCopyWriter: CopyFileWriter {
    private let base: any CopyFileWriter
    private let failAfter: Int
    private var written = 0

    init(base: any CopyFileWriter, failAfter: Int) {
        self.base = base
        self.failAfter = failAfter
    }

    var temporaryPath: String { base.temporaryPath }

    func write(_ data: Data) throws {
        guard written + data.count <= failAfter else {
            throw InspectFileSystemError("the test writer failed after \(written) bytes")
        }
        try base.write(data)
        written += data.count
    }

    func sync() throws { try base.sync() }
    func commit() throws { try base.commit() }
    func abort() { base.abort() }
}

// MARK: - Tool image recorder

private final class ToolImageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var firstBytes: [Data] = []

    var snapshot: ([String], [Data]) {
        lock.lock()
        defer { lock.unlock() }
        return (paths, firstBytes)
    }

    func record(_ path: String) {
        let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let head = (try? handle?.read(upToCount: 3)) ?? Data()
        try? handle?.close()
        lock.lock()
        paths.append(path)
        firstBytes.append(head)
        lock.unlock()
    }
}
