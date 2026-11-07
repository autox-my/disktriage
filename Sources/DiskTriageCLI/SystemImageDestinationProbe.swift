import Foundation
import Darwin
import DiskTriageCore
import DiskTriageCollectors

/// The shipped destination probe: read-only `statfs` facts, file existence and
/// a walk from the destination volume to its physical whole disk(s).
///
/// On macOS 27.2 `diskutil info -plist <file path>` exits 1, so the plan's
/// "diskutil info of the destination path" is satisfied by asking `statfs` for
/// the mounted volume and then walking that volume's whole disk to its
/// physical store (`disk3` → `disk0`). No file is created or written.
///
/// While DiskArbitration is stopped that walk must not run `diskutil` either:
/// `ioreg -r -c IOMedia -w 0` carries the same parent chain (an APFS
/// container's synthesized media is a child of its store partition), and the
/// pure `IORegMediaTree` resolves it. A `diskutil` timeout falls back the same
/// way once.
public struct SystemImageDestinationProbe: ImageDestinationProbing {
    private let executor: any CommandExecuting
    private let diskArbitration: DiskArbitrationProbe

    public init(
        executor: any CommandExecuting = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executor = executor
        self.diskArbitration = DiskArbitrationProbe(executor: executor, environment: environment)
    }

    public func probe(destination: String, mapfile: String) -> DestinationFacts {
        let manager = FileManager.default
        let destinationExists = manager.fileExists(atPath: destination)
        let mapfileExists = manager.fileExists(atPath: mapfile)

        let sidecarPath = destination + ".disktriage.json"
        var sidecar: ImageSidecar?
        var sidecarError: String?
        if manager.fileExists(atPath: sidecarPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
                sidecar = try JSONDecoder().decode(ImageSidecar.self, from: data)
            } catch {
                sidecarError = error.localizedDescription
            }
        }

        let parent = (destination as NSString).deletingLastPathComponent
        let parentDirectory = parent.isEmpty ? "." : parent
        var parentExists = false
        var isDirectory: ObjCBool = false
        parentExists = manager.fileExists(atPath: parentDirectory, isDirectory: &isDirectory)
            && isDirectory.boolValue

        guard parentExists else {
            return DestinationFacts(
                destinationExists: destinationExists,
                mapfileExists: mapfileExists,
                sidecar: sidecar,
                sidecarError: sidecarError,
                freeBytes: nil,
                containerFilesystem: nil,
                parentIsWritable: false,
                backingWholeDisk: nil,
                backingError: "the destination directory \(parentDirectory) does not exist"
            )
        }

        // The destination itself or its nearest existing parent, exactly as
        // the plan states: a file that does not exist yet is still on the
        // parent's filesystem.
        let statsPath = Self.nearestExistingPath(for: destination) ?? parentDirectory
        var stats = statfs()
        let rc = statsPath.withCString { statfs($0, &stats) }
        guard rc == 0 else {
            return DestinationFacts(
                destinationExists: destinationExists,
                mapfileExists: mapfileExists,
                sidecar: sidecar,
                sidecarError: sidecarError,
                freeBytes: nil,
                containerFilesystem: nil,
                parentIsWritable: manager.isWritableFile(atPath: parentDirectory),
                backingWholeDisk: nil,
                backingError: "statfs \(statsPath) failed: \(String(cString: strerror(errno)))"
            )
        }

        // `f_bavail` is the space available to an unprivileged writer, which
        // is the honest number for this check.
        let freeBytes = Int64(stats.f_bavail) * Int64(stats.f_bsize)
        let filesystem = cString(&stats.f_fstypename)
        let mountDevice = cString(&stats.f_mntfromname)

        let resolution = Self.resolveBackingDisks(
            mountSource: mountDevice,
            executor: executor,
            diskutilSkipReason: diskArbitration.diskutilSkipReason()
        )

        return DestinationFacts(
            destinationExists: destinationExists,
            mapfileExists: mapfileExists,
            sidecar: sidecar,
            sidecarError: sidecarError,
            freeBytes: freeBytes,
            containerFilesystem: filesystem,
            parentIsWritable: manager.isWritableFile(atPath: parentDirectory),
            backingError: resolution.error,
            backingWholeDisks: resolution.disks
        )
    }

    private static func nearestExistingPath(for path: String) -> String? {
        var candidate = path
        while true {
            if candidate.isEmpty { candidate = "." }
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            if candidate == "/" || candidate == "." { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }
}

// MARK: - The backing-disk walk

/// What the walk established, and why it failed when it did. `source` is only
/// for the smoke report; the destination rule never treats it as a fact.
struct BackingDiskResult: Equatable {
    let disks: [String]
    let error: String?
    let source: String
}

extension SystemImageDestinationProbe {
    /// Resolves the destination's physical whole disk(s).
    ///
    /// `diskutilSkipReason` non-nil means `diskutil` must not be run at all
    /// (DiskArbitration stopped, or the test-only force). Otherwise the
    /// recorded `diskutil info` walk runs first; a timeout falls back to ioreg
    /// once, so a wedged `diskutil` cannot block the check.
    static func resolveBackingDisks(
        mountSource: String,
        executor: any CommandExecuting,
        diskutilSkipReason: String?
    ) -> BackingDiskResult {
        if let reason = diskutilSkipReason {
            var result = resolveBackingDisksFromIOReg(mountSource: mountSource, executor: executor)
            if let error = result.error {
                result = BackingDiskResult(
                    disks: [],
                    error: "\(error) (\(reason))",
                    source: result.source
                )
            }
            return result
        }
        return resolveBackingDisksWithDiskutil(mountSource: mountSource, executor: executor)
    }

    private static func resolveBackingDisksWithDiskutil(
        mountSource: String,
        executor: any CommandExecuting
    ) -> BackingDiskResult {
        guard let whole = wholeDiskName(fromDevicePath: mountSource) else {
            return BackingDiskResult(
                disks: [],
                error: "cannot map the mount device \(mountSource) to a local whole disk",
                source: "diskutil"
            )
        }

        var current = whole
        for _ in 0..<3 {
            let result = executor.run(.diskutilInfo(disk: current))
            guard result.outcome == .ok, let data = result.stdout.data(using: .utf8) else {
                if result.outcome == .timeout {
                    var fallback = resolveBackingDisksFromIOReg(
                        mountSource: mountSource,
                        executor: executor
                    )
                    if let error = fallback.error {
                        fallback = BackingDiskResult(
                            disks: [],
                            error: "diskutil info \(current) timed out after \(result.durationMs) ms; \(error)",
                            source: fallback.source
                        )
                    }
                    return fallback
                }
                return BackingDiskResult(
                    disks: [],
                    error: "diskutil info \(current) \(result.outcome.rawValue)",
                    source: "diskutil"
                )
            }
            guard let next = physicalBackingDisk(fromInfoPList: data, current: current) else {
                return BackingDiskResult(
                    disks: [],
                    error: "diskutil info \(current) did not name a physical backing disk",
                    source: "diskutil"
                )
            }
            if next == current {
                return BackingDiskResult(disks: [current], error: nil, source: "diskutil")
            }
            current = next
        }
        return BackingDiskResult(
            disks: [],
            error: "the backing-disk walk did not settle",
            source: "diskutil"
        )
    }

    private static func resolveBackingDisksFromIOReg(
        mountSource: String,
        executor: any CommandExecuting
    ) -> BackingDiskResult {
        let result = executor.run(.ioregMediaTree)
        guard result.outcome == .ok else {
            return BackingDiskResult(
                disks: [],
                error: "ioreg media tree \(result.outcome.rawValue) after \(result.durationMs) ms",
                source: "ioreg"
            )
        }
        guard let tree = IORegMediaTree.parse(result.stdout) else {
            return BackingDiskResult(
                disks: [],
                error: "ioreg media tree did not parse",
                source: "ioreg"
            )
        }
        switch BackingDiskResolver.resolve(mountSource: mountSource, tree: tree) {
        case .wholeDisks(let disks):
            return BackingDiskResult(disks: disks, error: nil, source: "ioreg")
        case .unknown(let reason):
            return BackingDiskResult(disks: [], error: reason, source: "ioreg")
        }
    }
}

/// A C fixed-size character tuple (`f_fstypename`, `f_mntfromname`) as a
/// Swift string.
private func cString<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}
