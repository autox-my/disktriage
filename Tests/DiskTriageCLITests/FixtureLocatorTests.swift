import Foundation
import Testing
import DiskTriageTestSupport

/// The one place the live NTFS tests find their prefix and images:
/// `TestFixtures`. A fresh clone has no `captures/`, so the locator must use
/// the environment override or the bootstrap output and never the old
/// untracked spike tree.
struct FixtureLocatorTests {

    // REQ-0257
    @Test("REQ0257 the fixture locator uses the environment, then the bootstrap output, never captures/")
    func REQ0257_locatorUsesEnvThenBootstrapNeverCaptures() throws {
        let temp = TempDir()
        let root = try temp.makeDirectory("root")
        let prefix = root + "/.build/ntfs-prefix"
        let fixtures = root + "/.build/fixtures/ntfs"
        try makePrefix(prefix)
        try makeFixtures(fixtures)

        // 1. The bootstrap output is found when the environment is empty.
        #expect(TestFixtures.ntfsPrefix(environment: [:], root: root) == prefix)
        #expect(TestFixtures.fixtureDirectory(environment: [:], root: root) == fixtures)
        #expect(TestFixtures.ntfsDiskImage(environment: [:], root: root) == fixtures + "/disk.img")
        #expect(TestFixtures.damagedClipFixture(environment: [:], root: root)?.image
                == fixtures + "/damaged-clip-part.img")

        // 2. An environment override wins over the bootstrap output.
        let envPrefix = try temp.makeDirectory("env-prefix")
        let envFixtures = try temp.makeDirectory("env-fixtures")
        try makePrefix(envPrefix)
        try makeFixtures(envFixtures)
        let environment = [
            "DISKTRIAGE_NTFS_PREFIX": envPrefix,
            "DISKTRIAGE_FIXTURE_DIR": envFixtures,
        ]
        #expect(TestFixtures.ntfsPrefix(environment: environment, root: root) == envPrefix)
        #expect(TestFixtures.fixtureDirectory(environment: environment, root: root) == envFixtures)

        // 3. An incomplete override fails closed: it does not fall through to
        //    the valid bootstrap output, so a typo is a finding, not a silent
        //    pass on the wrong prefix.
        let broken = ["DISKTRIAGE_NTFS_PREFIX": temp.path + "/missing"]
        #expect(TestFixtures.ntfsPrefix(environment: broken, root: root) == nil)

        // 4. `captures/` is never consulted, even when it is complete.
        let capturesOnly = try temp.makeDirectory("captures-only")
        try makePrefix(capturesOnly + "/captures/ntfs-spike/prefix")
        try makeFixtures(capturesOnly + "/captures/ntfs-spike/img")
        #expect(TestFixtures.ntfsPrefix(environment: [:], root: capturesOnly) == nil)
        #expect(TestFixtures.fixtureDirectory(environment: [:], root: capturesOnly) == nil)
        #expect(TestFixtures.ntfsDiskImage(environment: [:], root: capturesOnly) == nil)
        #expect(TestFixtures.damagedClipFixture(environment: [:], root: capturesOnly) == nil)
    }

    private func makePrefix(_ prefix: String) throws {
        for tool in ["bin/ntfsinfo", "bin/ntfsls", "sbin/mkntfs"] {
            let path = prefix + "/" + tool
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
            else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path
            )
        }
    }

    private func makeFixtures(_ directory: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory), withIntermediateDirectories: true
        )
        for name in ["disk.img", "damaged-clip-part.img", "damaged-clip-part.mapfile"] {
            let path = directory + "/" + name
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}
