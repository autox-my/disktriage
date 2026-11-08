import Foundation
import CryptoKit
import DiskTriageCore
import DiskTriageCollectors

/// One file the copy loop may write. `listedSize` is the size the listing
/// reported; it is used only for caps and is never trusted as the byte count.
struct CopyLoopFile {
    let path: String
    let listedSize: Int64?
}

struct CopyLoopInput {
    let files: [CopyLoopFile]
    let destination: String
    /// Streams one volume-relative path in bounded chunks. NTFS supplies
    /// `ntfscat`; a native filesystem supplies the mounted file.
    let streamer: (String, Int, @escaping (Data) throws -> Void) -> CommandStreamResult
    let attribution: CopyAttribution
    let runByteCap: Int64?
    let chunkSize: Int
    let chunkObserver: (any CopyChunkObserving)?
}

struct CopyLoopOutput {
    var entries: [CopyManifestEntry] = []
    var bytesRead: Int64 = 0
    var bytesWritten: Int64 = 0
    var failed = 0
    var hashesAgree = true
    var budgetStopped = false
    var notes: [String] = []
}

/// The shared copy loop: stream one file, hash what was read, write it through
/// the temporary-file writer, read it back, hash that, and install only when
/// the hashes agree. The source is a streamer, so NTFS (`ntfscat`) and a native
/// mounted file use exactly the same caps, hashing and manifest rules.
func runCopyLoop(_ input: CopyLoopInput, fs: any CopyFileSystem) -> CopyLoopOutput {
    var output = CopyLoopOutput()
    var totalRead = output.bytesRead
    var totalWritten = output.bytesWritten
    var failed = output.failed
    var allHashesAgree = output.hashesAgree
    var entries = output.entries
    var budgetStopped = output.budgetStopped
    var notes = output.notes
    let started = Date()

for (index, file) in input.files.enumerated() {
    if Date().timeIntervalSince(started) > CopyLimits.totalTimeout {
        notes.append(
            "stopped after \(Int(CopyLimits.totalTimeout)) s; the remaining "
                + "\(input.files.count - index) file(s) were not attempted"
        )
        budgetStopped = true
        break
    }
    if let cap = input.runByteCap, totalRead >= cap {
        notes.append(
            "stopped at the \(cap)-byte --max-bytes cap; the remaining "
                + "\(input.files.count - index) file(s) were not attempted"
        )
        budgetStopped = true
        break
    }
    if let listedSize = file.listedSize, listedSize > CopyLimits.maxFileBytes {
        notes.append(
            "\(file.path) is \(listedSize) bytes, above the "
                + "\(CopyLimits.maxFileBytes)-byte per-file cap; it was not copied"
        )
        failed += 1
        allHashesAgree = false
        entries.append(CopyManifestEntry(
            path: CopyPathRules.relative(file.path),
            sizeBytes: listedSize,
            sha256Read: nil,
            sha256Written: nil,
            integrity: nil,
            attribution: nil,
            status: "skipped",
            note: "above the per-file byte cap"
        ))
        continue
    }
    if let cap = input.runByteCap, let listedSize = file.listedSize, totalRead + listedSize > cap {
        notes.append(
            "\(file.path) is \(listedSize) bytes and would exceed the \(cap)-byte "
                + "--max-bytes cap; it was not copied"
        )
        failed += 1
        allHashesAgree = false
        entries.append(CopyManifestEntry(
            path: CopyPathRules.relative(file.path),
            sizeBytes: listedSize,
            sha256Read: nil,
            sha256Written: nil,
            integrity: nil,
            attribution: nil,
            status: "skipped",
            note: "would exceed the --max-bytes cap"
        ))
        continue
    }

    let target = destinationPath(input.destination, file.path)
    let writer: any CopyFileWriter
    do {
        writer = try fs.makeWriter(to: target)
    } catch {
        failed += 1
        allHashesAgree = false
        entries.append(CopyManifestEntry(
            path: CopyPathRules.relative(file.path),
            sizeBytes: file.listedSize,
            sha256Read: nil,
            sha256Written: nil,
            integrity: nil,
            attribution: nil,
            status: "incomplete",
            note: "cannot create the destination file: \(describe(error))"
        ))
        notes.append("\(file.path) was not copied: \(describe(error))")
        continue
    }

    var readHasher = SHA256()
    var streamedBytes: Int64 = 0
    var stop: CopyStreamStop?

    let cat = input.streamer(file.path, input.chunkSize) { chunk in
        input.chunkObserver?.chunkAcquired()
        defer { input.chunkObserver?.chunkReleased() }

        if let cap = input.runByteCap,
           totalRead + streamedBytes + Int64(chunk.count) > cap {
            stop = .runCap(limit: cap)
            throw CopyStreamStopError.cap
        }
        if streamedBytes + Int64(chunk.count) > CopyLimits.maxFileBytes {
            stop = .fileCap(limit: CopyLimits.maxFileBytes)
            throw CopyStreamStopError.cap
        }
        do {
            try writer.write(chunk)
        } catch {
            let message = describe(error)
            stop = .writeFailed(message)
            throw CopyStreamStopError.write(message)
        }
        // Hash only bytes that were written, and every byte including
        // the last partial chunk (REQ-0145).
        readHasher.update(data: chunk)
        streamedBytes += Int64(chunk.count)
    }

    if let stop {
        writer.abort()
        failed += 1
        allHashesAgree = false
        let note: String
        switch stop {
        case .runCap(let limit):
            note = "the \(limit)-byte --max-bytes cap stopped the copy after "
                + "\(streamedBytes) bytes; the partial file was discarded"
            budgetStopped = true
            let remaining = input.files.count - index - 1
            if remaining > 0 {
                notes.append(
                    "stopped at the \(limit)-byte --max-bytes cap; the remaining "
                        + "\(remaining) file(s) were not attempted"
                )
            }
        case .fileCap(let limit):
            note = "the \(limit)-byte per-file cap stopped the copy after "
                + "\(streamedBytes) bytes; the partial file was discarded"
        case .writeFailed(let message):
            note = "the destination write failed after \(streamedBytes) bytes "
                + "(\(message)); the partial file was discarded"
        }
        entries.append(CopyManifestEntry(
            path: CopyPathRules.relative(file.path),
            sizeBytes: streamedBytes > 0 ? streamedBytes : file.listedSize,
            sha256Read: nil,
            sha256Written: nil,
            integrity: nil,
            attribution: nil,
            status: "incomplete",
            note: note
        ))
        notes.append("\(file.path) is incomplete: \(note)")
        // A run cap stops the run; a per-file cap or a write failure
        // only stops this file.
        if case .runCap = stop { break }
        continue
    }

    guard cat.outcome == .ok else {
        writer.abort()
        failed += 1
        allHashesAgree = false
        if cat.outcome == .timeout {
            let note = "ntfscat did not finish within its hard timeout; "
                + "\(streamedBytes) bytes were discarded and the file is incomplete"
            entries.append(CopyManifestEntry(
                path: CopyPathRules.relative(file.path),
                sizeBytes: streamedBytes > 0 ? streamedBytes : file.listedSize,
                sha256Read: nil,
                sha256Written: nil,
                integrity: nil,
                attribution: nil,
                status: "incomplete",
                note: note
            ))
            notes.append("\(file.path) is incomplete: \(note)")
        } else {
            let note: String
            switch cat.outcome {
            case .denied:
                note = "ntfscat was denied: " + (firstLine(trimmed(cat.stderr)) ?? "no message")
            case .notFound:
                note = "ntfscat disappeared before exec"
            case .policyRejected:
                note = "the ntfscat command was rejected by the command policy"
            default:
                note = cat.consumerError
                    ?? firstLine(trimmed(cat.stderr))
                    ?? "ntfscat exited \(cat.exitCode.map(String.init) ?? "on a signal")"
            }
            entries.append(CopyManifestEntry(
                path: CopyPathRules.relative(file.path),
                sizeBytes: file.listedSize,
                sha256Read: nil,
                sha256Written: nil,
                integrity: nil,
                attribution: nil,
                status: "read-error",
                note: note
            ))
            notes.append("\(file.path) was not copied: \(note)")
        }
        continue
    }

    // The temporary file is read back before it is installed: this is
    // what proves the write landed and catches a corrupting writer.
    // A mismatch aborts the temporary file, so no bad final file
    // exists (REQ-0144).
    do {
        try writer.sync()
        var readBackHasher = SHA256()
        let readBackBytes = try fs.readChunks(
            writer.temporaryPath,
            chunkSize: input.chunkSize
        ) { data in
            readBackHasher.update(data: data)
        }
        let readHash = readHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let writtenHash = readBackHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        let agree = readBackBytes == streamedBytes && writtenHash == readHash

        let integrity: CopyFileIntegrity? = input.attribution.kind == "ntfscluster"
            ? (input.attribution.integrity[file.path] ?? .intact)
            : nil

        if agree {
            try writer.commit()
            totalRead += streamedBytes
            totalWritten += readBackBytes
            entries.append(CopyManifestEntry(
                path: CopyPathRules.relative(file.path),
                sizeBytes: streamedBytes,
                sha256Read: readHash,
                sha256Written: writtenHash,
                integrity: integrity,
                attribution: integrity == nil ? nil : "ntfscluster",
                status: "ok",
                note: nil
            ))
        } else {
            writer.abort()
            failed += 1
            allHashesAgree = false
            entries.append(CopyManifestEntry(
                path: CopyPathRules.relative(file.path),
                sizeBytes: streamedBytes,
                sha256Read: readHash,
                sha256Written: writtenHash,
                integrity: integrity,
                attribution: integrity == nil ? nil : "ntfscluster",
                status: "hash-mismatch",
                note: "the bytes read back differ from the bytes written"
            ))
            notes.append(
                "\(file.path): written hash \(writtenHash) does not match read hash \(readHash)"
            )
        }
    } catch {
        writer.abort()
        failed += 1
        allHashesAgree = false
        entries.append(CopyManifestEntry(
            path: CopyPathRules.relative(file.path),
            sizeBytes: streamedBytes > 0 ? streamedBytes : file.listedSize,
            sha256Read: nil,
            sha256Written: nil,
            integrity: nil,
            attribution: nil,
            status: "incomplete",
            note: "the destination write failed after \(streamedBytes) bytes "
                + "(\(describe(error))); the partial file was discarded"
        ))
        notes.append(
            "\(file.path) is incomplete: \(describe(error)); the partial file was discarded"
        )
    }
}

    output.entries = entries
    output.bytesRead = totalRead
    output.bytesWritten = totalWritten
    output.failed = failed
    output.hashesAgree = allHashesAgree
    output.budgetStopped = budgetStopped
    output.notes = notes
    return output
}
