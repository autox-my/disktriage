import Foundation
import DiskTriageCore
import DiskTriageCollectors

// MARK: - The mounted-tree seam

/// One entry in a mounted volume, relative to the mountpoint. `path` has no
/// leading slash and uses `/` separators, so it is the volume-relative path
/// the manifest already uses for NTFS.
public struct MountedEntry: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let sizeBytes: Int64?

    public init(path: String, isDirectory: Bool, sizeBytes: Int64?) {
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
    }
}

public struct MountedListing: Equatable, Sendable {
    public let entries: [MountedEntry]
    /// The 10,000-entry cap was reached: the listing is partial, never a
    /// complete answer.
    public let truncated: Bool
    /// Symbolic links are skipped, never followed: a link in a damaged image
    /// must not escape the mountpoint.
    public let symlinksSkipped: Int

    public init(entries: [MountedEntry], truncated: Bool, symlinksSkipped: Int = 0) {
        self.entries = entries
        self.truncated = truncated
        self.symlinksSkipped = symlinksSkipped
    }

    public var directories: [String] {
        entries.filter(\.isDirectory).map(\.path)
    }

    public var rootEntries: Int {
        entries.filter { !$0.path.contains("/") }.count
    }
}

/// Reads the tree under a read-only mountpoint and streams file bytes. The
/// live implementation is the real filesystem; the tests inject a fake attach
/// that populates a temporary directory, so the copy loop still reads real
/// bytes.
public protocol MountedVolumeReading: Sendable {
    func listing(at root: String, maxEntries: Int) throws -> MountedListing
    func streamFile(
        at path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) throws -> Int64
}

public struct LiveMountedVolumeReader: MountedVolumeReading {
    public init() {}

    public func listing(at root: String, maxEntries: Int) throws -> MountedListing {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var entries: [MountedEntry] = []
        var symlinks = 0
        var truncated = false

        guard let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw InspectFileSystemError("cannot enumerate the mounted volume at \(root)")
        }

        let prefix: String = {
            let resolved = rootURL.resolvingSymlinksInPath().path
            return resolved.hasSuffix("/") ? resolved : resolved + "/"
        }()
        for case let item as URL in enumerator {
            if entries.count >= maxEntries {
                truncated = true
                break
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                symlinks += 1
                continue
            }
            let itemPath = item.resolvingSymlinksInPath().path
            let path = itemPath.hasPrefix(prefix)
                ? String(itemPath.dropFirst(prefix.count))
                : itemPath
            guard !path.isEmpty else { continue }
            if values?.isDirectory == true {
                entries.append(MountedEntry(path: path, isDirectory: true, sizeBytes: nil))
            } else if values?.isRegularFile == true {
                let size = values?.fileSize.map(Int64.init)
                entries.append(MountedEntry(path: path, isDirectory: false, sizeBytes: size))
            } else {
                // A socket, FIFO or device inside an image is not file data.
                symlinks += 1
            }
        }
        entries.sort { $0.path < $1.path }
        return MountedListing(entries: entries, truncated: truncated, symlinksSkipped: symlinks)
    }

    public func streamFile(
        at path: String,
        chunkSize: Int,
        consume: (Data) throws -> Void
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var total: Int64 = 0
        let capacity = max(1, chunkSize)
        while let data = try handle.read(upToCount: capacity), !data.isEmpty {
            try consume(data)
            total += Int64(data.count)
        }
        return total
    }
}

// MARK: - Report shapes

struct NativeAttachSummary {
    let wholeDisk: String
    let volumes: [NativeVolume]
}

struct NativeVolumeReport {
    let index: Int
    let device: String
    let name: String?
    let filesystem: NativeFilesystem
    let encrypted: Bool
    let locked: Bool
    var status: String
    var reason: String?
    var rootEntries: Int?
    var recursiveEntries: Int?
    var directories: Int?
    var truncated = false

    init(volume: NativeVolume) {
        index = volume.index
        device = volume.device
        name = volume.name
        filesystem = volume.filesystem
        encrypted = volume.encrypted
        locked = volume.locked
        status = "not-mounted"
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "volume \(index)"
    }
}

// MARK: - Resolution

func resolveNativeRunner(_ dependencies: InspectDependencies) -> (any NativeAttachRunning)? {
    if let injected = dependencies.native { return injected }
    guard dependencies.resolveNative,
          FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil")
    else { return nil }
    return LiveNativeAttachRunner.live()
}

func resolveMountedReader(_ dependencies: InspectDependencies) -> any MountedVolumeReading {
    dependencies.mountReader ?? LiveMountedVolumeReader()
}

func makeMountPoint(root: String?) throws -> String {
    let base = root ?? FileManager.default.temporaryDirectory.path
    let path = base.hasSuffix("/")
        ? base + "disktriage-mount-\(UUID().uuidString)"
        : base + "/disktriage-mount-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path),
        withIntermediateDirectories: true
    )
    return path
}

@discardableResult
func removeMountPoint(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return true }
    do {
        try FileManager.default.removeItem(atPath: path)
        return true
    } catch {
        return false
    }
}

private let nativeReadOnlyNote = "the image was attached read-only with "
    + "diskutil image attach --noMount --readOnly and mounted readOnly nobrowse; "
    + "the image was never written"

private func attributionNote(_ filesystem: NativeFilesystem) -> String {
    "per-file attribution is not available for \(filesystem.displayName): "
        + "F_LOG2PHYS_EXT is an open P0 item (diskdoctor.md §8), so damage is "
        + "reported at volume level only"
}

// MARK: - inspect

/// Inspects a native filesystem image: attach read-only, list every volume,
/// report mapfile damage at volume level, unmount and detach on every path.
func inspectNative(
    image: String,
    layout: LayoutReport,
    filesystem: NativeFilesystem,
    options: InspectOptions,
    dependencies: InspectDependencies,
    report: inout InspectReport
) -> CLIResult {
    func fail(_ status: InspectStatus, _ code: Int32, _ message: String) -> CLIResult {
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
            let lease = NativeAttachmentLease(runner: runner, wholeDisk: partialWholeDisk)
            _ = lease.cleanup()
        }
        return fail(.toolError, 30, "the image could not be attached: \(reason)")
    case .attached(let attachment):
        report.attachment = NativeAttachSummary(
            wholeDisk: attachment.wholeDisk,
            volumes: attachment.volumes.enumerated().map { index, volume in
                NativeVolume(
                    index: index + 1,
                    device: volume.device,
                    name: volume.name,
                    filesystem: volume.filesystem,
                    encrypted: volume.encrypted,
                    locked: volume.locked
                )
            }
        )

        let matchingVolumes = attachment.volumes.filter { $0.filesystem == filesystem }
        let numbered = matchingVolumes.enumerated().map { index, volume in
            NativeVolume(
                index: index + 1,
                device: volume.device,
                name: volume.name,
                filesystem: volume.filesystem,
                encrypted: volume.encrypted,
                locked: volume.locked
            )
        }
        guard !numbered.isEmpty else {
            let lease = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk)
            _ = lease.cleanup()
            return fail(
                .toolError,
                30,
                "the image attached as \(attachment.wholeDisk) but it contains no "
                    + "\(filesystem.displayName) volume to inspect"
            )
        }

        let lease = NativeAttachmentLease(runner: runner, wholeDisk: attachment.wholeDisk)
        NativeCleanupRegistry.shared.register(lease)

        var volumes: [NativeVolumeReport] = []
        var mountedAny = false
        for volume in numbered {
            var entry = NativeVolumeReport(volume: volume)
            if volume.locked {
                entry.status = "locked"
                entry.reason = "encrypted and locked; disktriage never prompts for a "
                    + "passphrase"
                volumes.append(entry)
                continue
            }

            let mountPoint: String
            do {
                mountPoint = try makeMountPoint(root: dependencies.mountPointRoot)
            } catch {
                entry.status = "error"
                entry.reason = "cannot create a mountpoint: \(describe(error))"
                volumes.append(entry)
                continue
            }

            lease.recordMountAttempt(volume.device)
            let mounted = runner.mountReadOnly(volume: volume.device, mountPoint: mountPoint)
            switch mounted {
            case .ok:
                break
            case .timedOut(let reason):
                entry.status = "timeout"
                entry.reason = reason
                removeMountPoint(mountPoint)
                volumes.append(entry)
                continue
            case .unavailable(let reason), .failed(let reason):
                entry.status = "error"
                entry.reason = reason
                removeMountPoint(mountPoint)
                volumes.append(entry)
                continue
            }

            do {
                let listing = try reader.listing(at: mountPoint, maxEntries: 10_000)
                entry.status = listing.truncated ? "partial" : "ok"
                entry.rootEntries = listing.rootEntries
                entry.recursiveEntries = listing.entries.count
                entry.directories = listing.directories.count
                entry.truncated = listing.truncated
                if listing.truncated {
                    entry.reason = "the listing reached the 10,000-entry cap; it is not "
                        + "a complete answer"
                }
                if listing.symlinksSkipped > 0 {
                    entry.reason = (entry.reason.map { $0 + "; " } ?? "")
                        + "\(listing.symlinksSkipped) symbolic link(s) were not followed"
                }
                mountedAny = true
            } catch {
                entry.status = "error"
                entry.reason = "cannot list the mounted volume: \(describe(error))"
            }

            let unmounted = runner.unmount(volume: volume.device)
            lease.recordUnmount()
            if !unmounted.isOK {
                entry.status = "partial"
                entry.reason = (entry.reason.map { $0 + "; " } ?? "")
                    + "unmount failed: \(unmounted.message ?? "unknown reason")"
            }
            if !removeMountPoint(mountPoint) {
                report.mountPointRemoved = false
                report.notes.append("the mountpoint \(mountPoint) could not be removed")
            }
            volumes.append(entry)
        }

        report.nativeVolumes = volumes

        if !mountedAny {
            let locked = volumes.filter { $0.status == "locked" }
            _ = lease.cleanup()
            if locked.count == volumes.count {
                return fail(
                    .toolError,
                    30,
                    "the volume is encrypted and locked: "
                        + volumes.map(\.displayName).joined(separator: ", ")
                        + ". disktriage never prompts for a passphrase; unlock it on a "
                        + "working copy or supply an unlocked image."
                )
            }
            let reasons = volumes.compactMap(\.reason).joined(separator: "; ")
            return fail(
                .toolError,
                30,
                "no \(filesystem.displayName) volume could be mounted: "
                    + (reasons.isEmpty ? "unknown reason" : reasons)
            )
        }

        // The top-level listing is the union of the volumes' listings.
        let rootEntries = volumes.compactMap(\.rootEntries).reduce(0, +)
        let recursiveEntries = volumes.compactMap(\.recursiveEntries).reduce(0, +)
        let directories = volumes.compactMap(\.directories).reduce(0, +)
        let truncated = volumes.contains(where: \.truncated)
        let listingStatus: String
        if volumes.contains(where: { $0.status == "timeout" }) {
            listingStatus = "timeout"
        } else if volumes.contains(where: { $0.status == "error" }) {
            listingStatus = "error"
        } else if volumes.contains(where: { $0.status == "partial" }) || truncated {
            listingStatus = "partial"
        } else {
            listingStatus = "ok"
        }
        report.listing = ListingReport(
            status: listingStatus,
            rootEntries: rootEntries,
            recursiveEntries: recursiveEntries,
            directories: directories,
            truncated: truncated,
            note: volumes.compactMap(\.reason).first
        )

        report.damage = readDamage(image: image, mapfile: options.mapfile, fs: dependencies.fileSystem)

        var code: Int32 = 0
        var status = InspectStatus.ok
        if volumes.contains(where: { $0.status == "partial" || $0.status == "timeout" })
            || report.damage.status == "error" {
            code = 30
            status = .toolError
            report.message = report.damage.note
                ?? "a volume was only partially inspected"
        } else {
            if volumes.contains(where: { $0.status == "error" }) {
                code = 1
                status = .partial
            }
            if let extents = report.damage.unreadableExtents, extents > 0 {
                code = 1
                status = .damage
            } else if report.damage.status == "ok", (report.damage.remainingBytes ?? 0) > 0 {
                code = 1
                status = .damage
            }
        }

        report.notes.append(nativeReadOnlyNote)
        report.notes.append(attributionNote(filesystem))
        if volumes.contains(where: \.locked) {
            report.notes.append(
                "a locked volume was not mounted and no passphrase was requested"
            )
        }

        let cleanup = lease.cleanup()
        if !cleanup.detach.isOK {
            code = 30
            status = .toolError
            report.message = "the image could not be detached from "
                + "\(attachment.wholeDisk): \(cleanup.detach.message ?? "unknown reason")"
            report.notes.append(report.message ?? "")
        }

        report.status = status
        report.exitCode = code
        return finish(report, options: options)
    }
}
