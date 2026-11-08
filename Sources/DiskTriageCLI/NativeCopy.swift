import Foundation
import DiskTriageCore
import DiskTriageCollectors

// MARK: - Resolution

func resolveNativeRunner(_ dependencies: CopyDependencies) -> (any NativeAttachRunning)? {
    if let injected = dependencies.native { return injected }
    guard dependencies.resolveNative,
          FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil")
    else { return nil }
    return LiveNativeAttachRunner.live()
}

func resolveMountedReader(_ dependencies: CopyDependencies) -> any MountedVolumeReading {
    dependencies.mountReader ?? LiveMountedVolumeReader()
}

// MARK: - copy

/// Copies the file tree of one native volume read-only. The route is the same
/// as `inspect`: attach the image with `--noMount --readOnly`, mount one
/// volume with `readOnly nobrowse`, stream the files, then unmount and detach.
/// Per-file damage attribution is deliberately not claimed: `F_LOG2PHYS_EXT`
/// is an open P0 item, so the manifest says `attribution: none` and the
/// damage section is volume-level.
func copyNative(
    image: String,
    imageSize: Int64,
    layout: LayoutReport,
    filesystem: NativeFilesystem,
    options: CopyOptions,
    dependencies: CopyDependencies,
    report: inout CopyReport
) -> CLIResult {
    let fs = dependencies.fileSystem

    func fail(_ status: CopyStatus, _ code: Int32, _ message: String) -> CLIResult {
        report.status = status
        report.exitCode = code
        report.message = message
        return finish(report, options: options)
    }

    guard let runner = resolveNativeRunner(dependencies) else {
        return fail(
            .toolError,
            30,
            "the native read-only attach is unavailable: /usr/sbin/diskutil was not "
                + "found (or the runner was not injected). No writable or third-party "
                + "fallback is attempted."
        )
    }
    let reader = resolveMountedReader(dependencies)
    if dependencies.installSignalTrap {
        NativeSignalTrap.install()
    }

    let attach = runner.attachReadOnly(image: image)
    switch attach {
    case .unavailable(let reason):
        return fail(.toolError, 30, reason)
    case .failed(let reason):
        return fail(.toolError, 30, "the image could not be attached: \(reason)")
    case .timedOut(let reason, let partialWholeDisk):
        if let partialWholeDisk {
            _ = NativeAttachmentLease(runner: runner, wholeDisk: partialWholeDisk).cleanup()
        }
        return fail(.toolError, 30, "the image could not be attached: \(reason)")
    case .attached(let attachment):
        let matching = attachment.volumes
            .filter { $0.filesystem == filesystem }
            .enumerated()
            .map { index, volume in
                NativeVolume(
                    index: index + 1,
                    device: volume.device,
                    name: volume.name,
                    filesystem: volume.filesystem,
                    encrypted: volume.encrypted,
                    locked: volume.locked
                )
            }
        report.attachment = NativeAttachSummary(
            wholeDisk: attachment.wholeDisk,
            volumes: matching
        )
        report.volumes = matching

        let selected: NativeVolume
        switch NativeVolumeSelection.select(matching, selector: options.volume) {
        case .success(let volume):
            selected = volume
        case .failure(.noVolumes):
            _ = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk).cleanup()
            return fail(
                .toolError,
                30,
                "the image attached as \(attachment.wholeDisk) but it contains no "
                    + "\(filesystem.displayName) volume to copy"
            )
        case .failure(.multipleVolumes):
            _ = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk).cleanup()
            return fail(
                .toolError,
                30,
                "the image contains \(matching.count) \(filesystem.displayName) volumes; "
                    + "choose one with --volume <name|index>: "
                    + NativeVolumeSelection.describe(matching)
            )
        case .failure(.unknownSelector(let selector)):
            _ = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk).cleanup()
            return fail(
                .toolError,
                30,
                "--volume '\(selector)' does not name exactly one volume; available: "
                    + NativeVolumeSelection.describe(matching)
            )
        }
        report.selectedVolume = selected

        if selected.locked {
            _ = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk).cleanup()
            return fail(
                .toolError,
                30,
                "the volume '\(selected.selectorName)' is encrypted and locked. "
                    + "disktriage never prompts for a passphrase; unlock it on a working "
                    + "copy or supply an unlocked image."
            )
        }

        let lease = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk)
        NativeCleanupRegistry.shared.register(lease)
        defer { _ = lease.cleanup() }

        let mountPoint: String
        do {
            mountPoint = try makeMountPoint(root: dependencies.mountPointRoot)
        } catch {
            return fail(.toolError, 30, "cannot create a mountpoint: \(describe(error))")
        }

        lease.recordMountAttempt(selected.device)
        let mounted = runner.mountReadOnly(volume: selected.device, mountPoint: mountPoint)
        guard mounted.isOK else {
            removeMountPoint(mountPoint)
            return fail(
                .toolError,
                30,
                "the volume '\(selected.selectorName)' could not be mounted read-only: "
                    + (mounted.message ?? "unknown reason")
            )
        }

        let listing: MountedListing
        do {
            listing = try reader.listing(at: mountPoint, maxEntries: CopyLimits.maxEntries)
        } catch {
            _ = runner.unmount(volume: selected.device)
            lease.recordUnmount()
            removeMountPoint(mountPoint)
            return fail(
                .toolError,
                30,
                "the file tree cannot be listed: \(describe(error))"
            )
        }

        var listingPartial = listing.truncated || listing.symlinksSkipped > 0
        if listing.truncated {
            report.notes.append(
                "the listing reached the \(CopyLimits.maxEntries)-entry cap; this is a partial copy"
            )
        }
        if listing.symlinksSkipped > 0 {
            report.notes.append(
                "\(listing.symlinksSkipped) symbolic link(s) were not followed; "
                    + "this is a partial copy"
            )
        }

        let directorySet = Set(listing.directories)
        var directories: [String] = []
        for directory in listing.directories where !directory.isEmpty {
            if let refusal = CopyPathRules.refusal(directory) {
                return fail(.toolError, 30, "refusing the directory name '\(directory)': \(refusal)")
            }
            directories.append(directory)
        }

        var files: [(path: String, listedSize: Int64?)] = []
        var seen: Set<String> = []
        for entry in listing.entries where !entry.isDirectory {
            guard !directorySet.contains(entry.path) else { continue }
            guard seen.insert(entry.path).inserted else { continue }
            if let refusal = CopyPathRules.refusal(entry.path) {
                return fail(.toolError, 30, "refusing the file name '\(entry.path)': \(refusal)")
            }
            files.append((entry.path, entry.sizeBytes))
        }
        files.sort { $0.path < $1.path }

        // No-overwrite is a precondition, checked before the first write.
        let destination = report.destination
        if fs.exists(destination) {
            for path in files.map(\.path) {
                let target = destinationPath(destination, path)
                if fs.exists(target) {
                    return fail(
                        .toolError,
                        30,
                        "\(target) already exists; copy never overwrites a file "
                            + "(choose an empty destination directory)"
                    )
                }
            }
            for directory in directories {
                let target = destinationPath(destination, directory)
                if fs.exists(target), !fs.isDirectory(target) {
                    return fail(.toolError, 30, "\(target) exists and is not a directory; copy never overwrites it")
                }
            }
            for reserved in ["MANIFEST.json", "SUMMARY.txt"] {
                let target = destination + "/" + reserved
                if fs.exists(target) {
                    return fail(.toolError, 30, "\(target) already exists; copy never overwrites it")
                }
            }
        }

        if options.hashImage {
            do {
                report.imageSHA256 = try sha256File(path: image, size: imageSize, fs: fs)
            } catch {
                return fail(.toolError, 30, "cannot hash \(image): \(describe(error))")
            }
        }

        // Damage is read before copying, so an unparsable mapfile stops the run
        // without writing anything.
        let damage = readDamage(
            image: image,
            mapfile: options.mapfile,
            fs: fs,
            audience: .copy
        )
        report.damage = damage
        if damage.status == "error" {
            return fail(.toolError, 30, damage.note ?? "the mapfile could not be read")
        }
        report.attribution = .unavailable(
            reason: damage.status == "ok"
                ? "per-file attribution is not available for \(filesystem.displayName): "
                    + "F_LOG2PHYS_EXT is an open P0 item (diskdoctor.md §8), so damage "
                    + "is reported at volume level only"
                : "no mapfile: damage is unknown, and absent is never a zero, so no "
                    + "per-file integrity is claimed"
        )

        do {
            if !fs.exists(destination) {
                try fs.createDirectory(destination)
            }
            for directory in directories {
                try fs.createDirectory(destinationPath(destination, directory))
            }
        } catch {
            return fail(.toolError, 30, "cannot create the destination tree: \(describe(error))")
        }

        let runByteCap = dependencies.maxBytesOverride ?? options.maxBytes
        let chunkSize = max(1, dependencies.chunkSize)
        let loop = runCopyLoop(
            CopyLoopInput(
                files: files.map { CopyLoopFile(path: $0.path, listedSize: $0.listedSize) },
                destination: destination,
                streamer: { path, chunk, consume in
                    do {
                        let bytes = try reader.streamFile(
                            at: mountPoint + "/" + path,
                            chunkSize: chunk,
                            consume: consume
                        )
                        return CommandStreamResult(outcome: .ok, exitCode: 0, bytesRead: bytes)
                    } catch {
                        return CommandStreamResult(
                            outcome: .error,
                            stderr: describe(error),
                            bytesRead: 0
                        )
                    }
                },
                attribution: report.attribution,
                runByteCap: runByteCap,
                chunkSize: chunkSize,
                chunkObserver: dependencies.chunkObserver
            ),
            fs: fs
        )

        let unmounted = runner.unmount(volume: selected.device)
        lease.recordUnmount()
        if !unmounted.isOK {
            listingPartial = true
            report.notes.append(
                "the read-only mount could not be unmounted cleanly: "
                    + (unmounted.message ?? "unknown reason")
            )
        }
        if !removeMountPoint(mountPoint) {
            report.notes.append("the mountpoint \(mountPoint) could not be removed")
        }

        report.notes.append(contentsOf: loop.notes)
        report.notes.append(
            "the image was attached read-only with diskutil image attach --noMount "
                + "--readOnly and mounted readOnly nobrowse; the image was never written"
        )

        let cleanup = lease.cleanup()
        var cleanupError: String?
        if !cleanup.detach.isOK {
            cleanupError = "the image could not be detached from \(attachment.wholeDisk): "
                + (cleanup.detach.message ?? "unknown reason")
            report.notes.append(cleanupError ?? "")
        }

        let result = completeCopy(
            report: &report,
            options: options,
            fs: fs,
            damage: damage,
            loop: loop,
            listingPartial: listingPartial,
            runByteCap: runByteCap,
            image: image,
            imageSize: imageSize,
            now: dependencies.now()
        )
        if let cleanupError {
            return CLIResult(
                stdout: result.stdout,
                stderr: "disktriage: \(cleanupError)\n",
                exitCode: 30
            )
        }
        return result
    }
}
