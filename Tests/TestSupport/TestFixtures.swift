import Foundation

/// Locates the NTFS live-test prefix and fixture images.
///
/// `scripts/bootstrap.sh` builds both under `.build/`; neither is committed
/// (the images are tens of MiB of incompressible data) and `captures/` is
/// untracked scratch a fresh clone does not have. The resolution order is:
///
/// 1. `DISKTRIAGE_NTFS_PREFIX` / `DISKTRIAGE_FIXTURE_DIR`;
/// 2. `<repository>/.build/ntfs-prefix` / `<repository>/.build/fixtures/ntfs`.
///
/// An environment override is final: an incomplete one returns `nil` rather
/// than silently falling back, so a typo is visible instead of hidden.
public enum TestFixtures {
    /// The checkout root, from this source file's compile-time path.
    public static let repositoryRoot: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestSupport
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .path
    }()

    /// A built ntfs-3g prefix with the tools the live tests drive.
    public static func ntfsPrefix(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String = repositoryRoot
    ) -> String? {
        if let override = environment["DISKTRIAGE_NTFS_PREFIX"], !override.isEmpty {
            return hasNTFSTools(override) ? override : nil
        }
        let bootstrap = root + "/.build/ntfs-prefix"
        return hasNTFSTools(bootstrap) ? bootstrap : nil
    }

    /// The directory holding `disk.img` and the damaged-copy fixture.
    public static func fixtureDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String = repositoryRoot
    ) -> String? {
        if let override = environment["DISKTRIAGE_FIXTURE_DIR"], !override.isEmpty {
            return hasDiskImage(override) ? override : nil
        }
        let bootstrap = root + "/.build/fixtures/ntfs"
        return hasDiskImage(bootstrap) ? bootstrap : nil
    }

    /// The 80 MiB whole-disk NTFS image.
    public static func ntfsDiskImage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String = repositoryRoot
    ) -> String? {
        fixtureDirectory(environment: environment, root: root).map { $0 + "/disk.img" }
    }

    /// The damaged `clip.dat` copy and its ddrescue mapfile.
    public static func damagedClipFixture(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String = repositoryRoot
    ) -> (image: String, mapfile: String)? {
        guard let directory = fixtureDirectory(environment: environment, root: root) else {
            return nil
        }
        let image = directory + "/damaged-clip-part.img"
        let mapfile = directory + "/damaged-clip-part.mapfile"
        guard FileManager.default.fileExists(atPath: image),
              FileManager.default.fileExists(atPath: mapfile)
        else { return nil }
        return (image, mapfile)
    }

    /// The native (APFS/HFS+/exFAT/FAT) live-test images.
    public static func nativeFixtureDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String = repositoryRoot
    ) -> String? {
        if let override = environment["DISKTRIAGE_NATIVE_FIXTURE_DIR"], !override.isEmpty {
            return hasNativeFixtures(override) ? override : nil
        }
        let bootstrap = root + "/.build/fixtures/native"
        return hasNativeFixtures(bootstrap) ? bootstrap : nil
    }

    public static func nativeFixture(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: String = repositoryRoot
    ) -> String? {
        guard let directory = nativeFixtureDirectory(environment: environment, root: root) else {
            return nil
        }
        let path = directory + "/" + name
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Whether a directory carries every native image the live tests read.
    public static func hasNativeFixtures(_ directory: String) -> Bool {
        [
            "exfat-disk.img", "exfat-part.img",
            "fat-disk.img", "fat-part.img",
            "hfs-disk.dmg", "hfs-part.img",
            "apfs-disk.img", "encrypted-apfs.img",
            "damaged-exfat-part.img", "damaged-exfat-part.mapfile",
        ].allSatisfy { FileManager.default.fileExists(atPath: directory + "/" + $0) }
    }

    /// `ddrescue` from the host, for the live tests that spawn it.
    public static func ddrescueExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        var candidates = [
            "/opt/homebrew/bin/ddrescue",
            "/usr/local/bin/ddrescue",
            "/usr/bin/ddrescue",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/ddrescue" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether a prefix carries `bin/ntfsinfo`, `bin/ntfsls` and `sbin/mkntfs`.
    public static func hasNTFSTools(_ prefix: String) -> Bool {
        ["bin/ntfsinfo", "bin/ntfsls", "sbin/mkntfs"].allSatisfy {
            FileManager.default.isExecutableFile(atPath: prefix + "/" + $0)
        }
    }

    /// Whether a directory carries the disk image the live tests read.
    public static func hasDiskImage(_ directory: String) -> Bool {
        FileManager.default.fileExists(atPath: directory + "/disk.img")
    }
}
