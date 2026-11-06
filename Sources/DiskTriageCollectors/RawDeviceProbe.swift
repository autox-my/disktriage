import Foundation
import Darwin
import DiskTriageCore

/// The one live device read the product performs: a 4096-byte read of the
/// **internal** disk's raw character node, without sudo.
///
/// 4096, not 512: Apple internal storage has a 4096-byte device block and raw
/// nodes want block-aligned reads, so a 512-byte read can return EINVAL after
/// access was granted (docs/p0-runbook.md, A3). The reader is injectable so no
/// test opens a device.
public struct RawDeviceProbe: Sendable {
    public static let readSize = 4096

    public typealias Reader = @Sendable (_ node: String, _ count: Int) -> FDAProbeEvidence

    private let reader: Reader

    public init(reader: @escaping Reader = RawDeviceProbe.read) {
        self.reader = reader
    }

    public func probe(node: String) -> FDAProbeEvidence {
        reader(node, Self.readSize)
    }

    /// `open(2)` + one aligned `read(2)`. Never writes, never seeks, never
    /// opens anything but the node it is given.
    public static func read(node: String, count: Int = readSize) -> FDAProbeEvidence {
        let fd = open(node, O_RDONLY)
        guard fd >= 0 else {
            return .failed(errno: errno, message: String(cString: strerror(errno)))
        }
        defer { close(fd) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: readSize)
        defer { buffer.deallocate() }

        let bytes = Darwin.read(fd, buffer, count)
        guard bytes >= 0 else {
            return .failed(errno: errno, message: String(cString: strerror(errno)))
        }
        return .read(bytes: bytes)
    }
}

/// Finds the internal whole disk to probe, from `diskutil list` and
/// `diskutil info -plist`. Synthesized APFS containers are virtual and are not
/// a probe source; an external disk is never touched.
public struct InternalDiskLocator: Sendable {
    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
    }

    public func internalRawNode() -> String? {
        let collector = DeviceCollector(executor: executor)
        let enumeration = collector.enumerate()
        guard enumeration.status == .ok else { return nil }

        for bsd in enumeration.disks {
            let collection = collector.collect(bsd: bsd)
            guard collection.status == .ok, let identity = collection.identity else { continue }
            guard identity.internalDisk == true else { continue }
            guard identity.virtualOrPhysical?.lowercased() != "virtual" else { continue }
            return "/dev/r\(identity.bsd)"
        }
        return nil
    }
}
