import Foundation
import Darwin
import DiskTriageCollectors

/// The shipped destination probe: read-only `statfs` facts, file existence and
/// one `diskutil info -plist` walk to the physical whole disk.
///
/// On macOS 27.2 `diskutil info -plist <file path>` exits 1, so the plan's
/// "diskutil info of the destination path" is satisfied by asking `statfs` for
/// the mounted volume and then walking that volume's whole disk to its
/// physical store (`disk3` → `disk0`). No file is created or written.
public struct SystemImageDestinationProbe: ImageDestinationProbing {
    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
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

        var stats = statfs()
        let rc = parentDirectory.withCString { statfs($0, &stats) }
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
                backingError: "statfs \(parentDirectory) failed: \(String(cString: strerror(errno)))"
            )
        }

        // `f_bavail` is the space available to an unprivileged writer, which
        // is the honest number for this check.
        let freeBytes = Int64(stats.f_bavail) * Int64(stats.f_bsize)
        let filesystem = cString(&stats.f_fstypename)
        let mountDevice = cString(&stats.f_mntfromname)

        var backingError: String?
        let backing = resolveBackingDisk(mountDevice: mountDevice, error: &backingError)

        return DestinationFacts(
            destinationExists: destinationExists,
            mapfileExists: mapfileExists,
            sidecar: sidecar,
            sidecarError: sidecarError,
            freeBytes: freeBytes,
            containerFilesystem: filesystem,
            parentIsWritable: manager.isWritableFile(atPath: parentDirectory),
            backingWholeDisk: backing,
            backingError: backingError
        )
    }

    /// `/dev/disk3s5` → `disk3` → its physical store `disk0`. A physical whole
    /// disk answers with itself. `nil` means the walk could not establish the
    /// backing disk, which the destination rule treats as unknown, never pass.
    private func resolveBackingDisk(mountDevice: String, error: inout String?) -> String? {
        guard let whole = wholeDiskName(fromDevicePath: mountDevice) else {
            error = "cannot map the mount device \(mountDevice) to a whole disk"
            return nil
        }

        var current = whole
        for _ in 0..<3 {
            let result = executor.run(.diskutilInfo(disk: current))
            guard result.outcome == .ok, let data = result.stdout.data(using: .utf8) else {
                error = "diskutil info \(current) \(result.outcome.rawValue)"
                return nil
            }
            guard let next = physicalBackingDisk(fromInfoPList: data, current: current) else {
                error = "diskutil info \(current) did not name a physical backing disk"
                return nil
            }
            if next == current {
                return current
            }
            current = next
        }
        error = "the backing-disk walk did not settle"
        return nil
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
