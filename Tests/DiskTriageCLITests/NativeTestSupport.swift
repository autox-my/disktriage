import Foundation
import DiskTriageCollectors
import DiskTriageCore

/// A scripted native attach: it records the calls the product makes and
/// "mounts" a real temporary directory with a fixed tree, so the live mounted
/// reader still reads real bytes. No `diskutil` runs.
final class ScriptedNativeRunner: NativeAttachRunning, @unchecked Sendable {
    enum Item {
        case file(Data)
        case directory
        case symlink(String)
    }

    private let lock = NSLock()
    private var storage: [String] = []
    private var tree: [String: Item] = [:]

    var attachResult: NativeAttachResult
    var mountResult: NativeCommandResult = .ok
    var unmountResult: NativeCommandResult = .ok
    var detachResult: NativeCommandResult = .ok
    /// Called inside `mountReadOnly`, so a test can assert the mountpoint was
    /// created and empty before the mount.
    var onMount: (@Sendable (String) -> Void)?

    init(attachResult: NativeAttachResult, tree: [String: Item] = [:]) {
        self.attachResult = attachResult
        self.tree = tree
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func record(_ call: String) {
        lock.lock()
        storage.append(call)
        lock.unlock()
    }

    func attachReadOnly(image: String) -> NativeAttachResult {
        record("attach:\(image)")
        return attachResult
    }

    func mountReadOnly(volume: String, mountPoint: String) -> NativeCommandResult {
        record("mount:\(volume)")
        onMount?(mountPoint)
        guard mountResult.isOK else { return mountResult }
        do {
            try populate(mountPoint)
            return .ok
        } catch {
            return .failed("cannot populate the fake mount: \(error)")
        }
    }

    func unmount(volume: String) -> NativeCommandResult {
        record("unmount:\(volume)")
        return unmountResult
    }

    func detach(wholeDisk: String) -> NativeCommandResult {
        record("detach:\(wholeDisk)")
        return detachResult
    }

    private func populate(_ root: String) throws {
        let manager = FileManager.default
        for path in tree.keys.sorted() {
            guard let item = tree[path] else { continue }
            let full = root + "/" + path
            switch item {
            case .directory:
                try manager.createDirectory(atPath: full, withIntermediateDirectories: true)
            case .file(let data):
                let parent = (full as NSString).deletingLastPathComponent
                try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: full))
            case .symlink(let target):
                let parent = (full as NSString).deletingLastPathComponent
                try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try manager.createSymbolicLink(atPath: full, withDestinationPath: target)
            }
        }
    }
}

/// A native attach that is not available at all, to prove the missing-runner
/// precondition without touching the host's `diskutil`.
final class UnavailableNativeRunner: NativeAttachRunning, @unchecked Sendable {
    func attachReadOnly(image: String) -> NativeAttachResult {
        .unavailable("the native read-only attach is unavailable in this test; no writable or third-party fallback is attempted")
    }
    func mountReadOnly(volume: String, mountPoint: String) -> NativeCommandResult {
        .unavailable("not mounted")
    }
    func unmount(volume: String) -> NativeCommandResult { .unavailable("not mounted") }
    func detach(wholeDisk: String) -> NativeCommandResult { .unavailable("not attached") }
}

func nativeAttachment(
    wholeDisk: String = "/dev/disk8",
    volumes: [(device: String, name: String?, filesystem: NativeFilesystem, locked: Bool)] = [
        ("/dev/disk8", "DT", .exfat, false)
    ]
) -> NativeAttachResult {
    .attached(NativeAttachment(
        wholeDisk: wholeDisk,
        volumes: volumes.map {
            NativeAttachedVolume(
                device: $0.device,
                name: $0.name,
                filesystem: $0.filesystem,
                encrypted: $0.locked,
                locked: $0.locked
            )
        }
    ))
}

/// The minimal bytes that make `FileSystemDetector` name a filesystem without
/// a real image. A bare volume has no MBR (`55 AA`), so `detectLayout` keeps it
/// a bare volume.
func syntheticImageBytes(filesystem: NativeFilesystem, size: Int = 4096) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size)
    switch filesystem {
    case .exfat:
        bytes.replaceSubrange(3..<11, with: Array("EXFAT   ".utf8))
    case .hfsPlus:
        bytes.replaceSubrange(1024..<1026, with: [0x48, 0x2B])
    case .fat:
        bytes.replaceSubrange(82..<90, with: Array("FAT32   ".utf8))
    case .apfs:
        bytes.replaceSubrange(32..<36, with: Array("NXSB".utf8))
    }
    return bytes
}

/// A whole-disk image: an MBR with one partition at byte 4096 holding the
/// synthetic filesystem magic.
func syntheticWholeDiskBytes(filesystem: NativeFilesystem) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 131_072)
    bytes[446 + 4] = 0x07
    for i in 0..<4 { bytes[446 + 8 + i] = UInt8((8 >> (8 * UInt32(i))) & 0xFF) }
    for i in 0..<4 { bytes[446 + 12 + i] = UInt8((128 >> (8 * UInt32(i))) & 0xFF) }
    bytes[510] = 0x55
    bytes[511] = 0xAA
    let magic = syntheticImageBytes(filesystem: filesystem, size: 2048)
    bytes.replaceSubrange(4096..<(4096 + magic.count), with: magic)
    return bytes
}
