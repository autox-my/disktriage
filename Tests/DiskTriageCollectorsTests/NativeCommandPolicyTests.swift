import Testing
import DiskTriageCollectors

/// The native attach policy is the narrowest allow-list in the product: an
/// image attach that is explicitly no-mount and read-only, an explicit
/// read-only nobrowse mount of one volume, and the unmount/detach/info calls
/// cleanup needs. There is no writable shape to reach by mistake.
struct NativeCommandPolicyTests {
    private let policy = CommandPolicy.native

    // REQ-0265, REQ-0266, REQ-0316, REQ-0319
    @Test("REQ0265_REQ0266_REQ0316_REQ0319 the read-only attach, mount, unmount, detach and info shapes are allowed")
    func REQ0265_REQ0266_REQ0316_REQ0319_allowsTheReadOnlyShapes() {
        let allowed: [[String]] = [
            ["/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly", "/tmp/x.img"],
            [
                "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
                "-mountPoint", "/tmp/disktriage-mount-x", "/dev/disk9s1",
            ],
            [
                "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
                "-mountPoint", "/tmp/disktriage-mount-x", "/dev/disk8",
            ],
            ["/usr/sbin/diskutil", "unmount", "/dev/disk9s1"],
            ["/usr/sbin/diskutil", "unmount", "/dev/disk8"],
            ["/usr/sbin/diskutil", "eject", "/dev/disk8"],
            ["/usr/sbin/diskutil", "info", "-plist", "/dev/disk9s1"],
            ["/usr/sbin/diskutil", "info", "-plist", "/dev/disk8"],
            ["/usr/bin/hdiutil", "info"],
        ]
        for argv in allowed {
            #expect(policy.evaluate(argv) == .allowed, "expected allowed: \(argv)")
        }
    }

    // REQ-0267, REQ-0268
    @Test("REQ0267_REQ0268 every writable, forced, third-party or wrongly-shaped argv is rejected")
    func REQ0267_REQ0268_rejectsWritableAndThirdPartyShapes() {
        let rejected: [[String]] = [
            [],
            ["/sbin/mount"],
            ["/sbin/mount_apfs", "/dev/disk4s1", "/Volumes/x"],
            ["/sbin/mount_ntfs", "/dev/disk4s1", "/Volumes/x"],
            ["/usr/bin/hdiutil", "attach", "-nomount", "/tmp/x.img"],
            ["/usr/bin/hdiutil", "info", "-plist"],
            ["/usr/sbin/diskutil", "mount", "disk4"],
            ["/usr/sbin/diskutil", "mountDisk", "disk4"],
            ["/usr/sbin/diskutil", "unmountDisk", "disk4"],
            ["/usr/sbin/diskutil", "eject", "disk4"],
            ["/usr/sbin/diskutil", "eject", "/dev/disk8s1"],
            ["/usr/sbin/diskutil", "image", "attach", "/tmp/x.img"],
            ["/usr/sbin/diskutil", "image", "attach", "--readOnly", "/tmp/x.img"],
            ["/usr/sbin/diskutil", "image", "attach", "--noMount", "/tmp/x.img"],
            ["/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly", "/dev/disk8"],
            [
                "/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly",
                "--mountPoint", "/tmp/m", "/tmp/x.img",
            ],
            [
                "/usr/sbin/diskutil", "mount", "nobrowse",
                "-mountPoint", "/tmp/m", "/dev/disk9s1",
            ],
            [
                "/usr/sbin/diskutil", "mount", "readOnly",
                "-mountPoint", "/tmp/m", "/dev/disk9s1",
            ],
            [
                "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
                "-mountOptions", "rw", "-mountPoint", "/tmp/m", "/dev/disk9s1",
            ],
            [
                "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
                "-mountPoint", "/tmp/m", "/dev/rdisk9s1",
            ],
            [
                "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
                "-mountPoint", "relative", "/dev/disk9s1",
            ],
            [
                "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
                "-mountPoint", "/dev/m", "/dev/disk9s1",
            ],
            ["/usr/sbin/diskutil", "unmount", "/dev/rdisk9s1"],
            ["/usr/sbin/diskutil", "unmount", "/dev/disk9s1", "extra"],
            ["/usr/sbin/diskutil", "info", "disk9s1"],
            ["/usr/sbin/diskutil", "info", "-plist", "/dev/rdisk9s1"],
            ["/usr/sbin/diskutil", "info", "-plist", "disk9s1"],
            ["/usr/sbin/diskutil", "apfs", "unlockVolume", "/dev/disk9s1"],
            ["/usr/sbin/diskutil", "apfs", "encryptVolume", "/dev/disk9s1"],
            ["/usr/sbin/diskutil", "image", "create", "blank", "/tmp/x.img"],
            ["/sbin/kextload", "/Library/Extensions/ms_ntfs.kext"],
            ["/usr/bin/kmutil", "load", "-i", "/Library/Extensions/ms_ntfs.kext"],
            ["/opt/homebrew/bin/brew", "install", "macfuse"],
        ]
        for argv in rejected {
            #expect(policy.evaluate(argv) != .allowed, "expected rejected: \(argv)")
        }
    }

    // REQ-0317
    @Test("REQ0317 an attach must say --noMount and --readOnly, in that order, with one absolute image")
    func REQ0317_attachShapeIsExact() {
        #expect(
            policy.evaluate([
                "/usr/sbin/diskutil", "image", "attach", "--readOnly", "--noMount", "/tmp/x.img",
            ]) != .allowed,
            "the flag order is part of the exact shape"
        )
        #expect(
            policy.evaluate([
                "/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly", "/tmp/x.img", "extra",
            ]) != .allowed
        )
    }

    // REQ-0318
    @Test("REQ0318 info accepts only whole-disk and volume device identifiers")
    func REQ0318_infoAcceptsOnlyDeviceIdentifiers() {
        for device in ["/dev/disk0", "/dev/disk12", "/dev/disk9s1", "/dev/disk12s34"] {
            #expect(
                policy.evaluate(["/usr/sbin/diskutil", "info", "-plist", device]) == .allowed,
                "\(device)"
            )
        }
        for device in ["/dev/disk", "/dev/disk9x1", "/dev/diskx", "/dev/disk9s", "/dev/disk9s1s2"] {
            #expect(
                policy.evaluate(["/usr/sbin/diskutil", "info", "-plist", device]) != .allowed,
                "\(device)"
            )
        }
    }

    // REQ-0315
    @Test("REQ0315 the mount shape is read-only and nobrowse, never a writable mount")
    func REQ0315_mountIsReadOnlyAndNobrowse() {
        let base = [
            "/usr/sbin/diskutil", "mount", "readOnly", "nobrowse",
            "-mountPoint", "/tmp/m", "/dev/disk9s1",
        ]
        #expect(policy.evaluate(base) == .allowed)
        for index in [2, 3] {
            var without = base
            without.remove(at: index)
            #expect(policy.evaluate(without) != .allowed,
                    "a mount without readOnly/nobrowse is rejected: \(without)")
        }
        var writable = base
        writable[2] = "readWrite"
        #expect(policy.evaluate(writable) != .allowed)
    }

    // REQ-0310
    @Test("REQ0310 the native policy does not widen the triage, check or inspect policies")
    func REQ0310_doesNotWidenTheOtherPolicies() {
        let nativeOnly: [[String]] = [
            ["/usr/sbin/diskutil", "mount", "readOnly", "nobrowse", "-mountPoint", "/tmp/m", "/dev/disk9s1"],
            ["/usr/sbin/diskutil", "unmount", "/dev/disk9s1"],
            ["/usr/sbin/diskutil", "eject", "/dev/disk8"],
            ["/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly", "/tmp/x.img"],
        ]
        for policy in [CommandPolicy.triage, .check, .inspect] {
            for argv in nativeOnly {
                #expect(policy.evaluate(argv) != .allowed, "\(policy) allowed: \(argv)")
            }
        }
    }
}
