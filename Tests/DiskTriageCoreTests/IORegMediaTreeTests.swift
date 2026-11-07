import Foundation
import Testing
@testable import DiskTriageCore

/// The destination's backing whole disk, read without DiskArbitration.
///
/// The io registry is a tree: a volume sits under its whole media, an APFS
/// synthesized container (`disk3`) sits under its physical store (`disk0s2`),
/// and either may be absent. Every expectation below is a recorded or
/// redacted shape, never a value recomputed the way the resolver computes it.
struct IORegMediaTreeTests {

    private func tree(_ name: String) throws -> IORegMediaTree {
        let text = String(decoding: try fixtureData(name), as: UTF8.self)
        return try #require(IORegMediaTree.parse(text), "\(name) parses as a media tree")
    }

    // REQ-0166: a plain volume (HFS/exFAT/NTFS) on a USB whole disk backs onto
    // that disk; no APFS walk is involved.
    @Test("REQ0166 plain HFS exFAT and NTFS volumes resolve to their USB whole disk")
    func REQ0166_plainVolumesResolveToTheirWholeDisk() throws {
        let parsed = try tree("ioreg-iomedia-tree-usb.txt")

        for slice in ["disk8s1", "disk8s2", "disk8s3"] {
            #expect(
                BackingDiskResolver.resolve(mountSource: "/dev/\(slice)", tree: parsed)
                    == .wholeDisks(["disk8"]),
                "\(slice) is backed by disk8"
            )
        }
        #expect(
            BackingDiskResolver.resolve(mountSource: "/dev/disk8", tree: parsed)
                == .wholeDisks(["disk8"]),
            "a whole disk answers with itself"
        )
    }

    // REQ-0166: the real shape on this Mac: `/` is disk3s* in the synthesized
    // container disk3, whose physical store is disk0s2 on the internal NVMe.
    @Test("REQ0166 an APFS volume resolves through its container to the internal NVMe")
    func REQ0166_apfsVolumeResolvesThroughItsStore() throws {
        let parsed = try tree("ioreg-iomedia-tree-internal-apfs.txt")

        #expect(
            BackingDiskResolver.resolve(mountSource: "/dev/disk3s5", tree: parsed)
                == .wholeDisks(["disk0"]),
            "the Data volume's store is disk0, not the synthesized disk3"
        )
        #expect(
            parsed.backingWholeDisks(forMountedWholeDisk: "disk3") == .wholeDisks(["disk0"]),
            "the container's whole disk walks to its store"
        )
    }

    // REQ-0166: an APFS container can have more than one physical store; every
    // store is a backing disk, and none may be dropped.
    @Test("REQ0166 an APFS container spanning two stores names both physical disks")
    func REQ0166_multiStoreContainerNamesEveryStore() throws {
        let parsed = try tree("ioreg-iomedia-tree-multistore.txt")

        #expect(
            BackingDiskResolver.resolve(mountSource: "/dev/disk3s5", tree: parsed)
                == .wholeDisks(["disk0", "disk5"]),
            "both physical stores are backing disks"
        )
    }

    // REQ-0170: fail closed. A network mount or an unknown filesystem has no
    // local backing disk, so the rule must be unverifiable, never a pass.
    @Test("REQ0170 a network mount and an unknown mount source are unverifiable")
    func REQ0170_unknownMountSourcesFailClosed() throws {
        let parsed = try tree("ioreg-iomedia-tree-internal-apfs.txt")

        for source in ["//server/share", "server:/export", "map auto_home", "devfs"] {
            guard case .unknown(let reason) = BackingDiskResolver.resolve(
                mountSource: source,
                tree: parsed
            ) else {
                Issue.record("\(source) must not resolve to a local disk")
                continue
            }
            #expect(!reason.isEmpty, "\(source) says why it is unknown")
        }
    }

    @Test("an empty or unrelated ioreg tree is unknown, not disk0")
    func unusableTreeIsUnknown() throws {
        #expect(
            BackingDiskResolver.resolve(mountSource: "/dev/disk3s5", tree: try tree("ioreg-iomedia-tree-usb.txt"))
                == .unknown("ioreg has no IOMedia for disk3"),
            "no invented disk"
        )
    }
}
