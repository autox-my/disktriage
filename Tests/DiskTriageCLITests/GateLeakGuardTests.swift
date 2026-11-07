import Foundation
import Testing
import DiskTriageTestSupport

/// The shared temp-directory helper: one directory per test, removed whether
/// the test passes, fails or throws, and read-only fixtures still removable.
struct TempDirTests {

    // REQ-0228
    @Test("REQ0228 a temporary directory and its contents are removed when it goes out of scope")
    func REQ0228_tempDirRemovesItselfAndItsContents() throws {
        weak var weakDirectory: TempDir?
        var path = ""
        do {
            let directory = TempDir()
            weakDirectory = directory
            path = directory.path
            try Data("payload".utf8).write(
                to: URL(fileURLWithPath: directory.child("payload.bin"))
            )
            try FileManager.default.createDirectory(
                atPath: directory.child("nested"),
                withIntermediateDirectories: true
            )
            #expect(FileManager.default.fileExists(atPath: path))
        }

        #expect(weakDirectory == nil, "the test's owner released the directory")
        #expect(!FileManager.default.fileExists(atPath: path),
                "the directory and its contents are gone: \(path)")
    }

    // REQ-0229
    @Test("REQ0229 removal makes read-only fixtures writable first")
    func REQ0229_removeMakesReadOnlyFixturesWritable() throws {
        let directory = TempDir()
        let readOnly = try directory.makeDirectory("read-only")
        let file = readOnly + "/snapshot.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly)

        directory.remove()

        #expect(!FileManager.default.fileExists(atPath: directory.path),
                "a 0500 directory with a 0400 file is still removable")
    }
}

/// The gate's leak guard, driven through the shipped `scripts/lib/temp-leak.sh`
/// on a fake temp root. It never looks at a real leftover.
struct GateLeakGuardTests {
    private let temp = TempDir()

    private static let libraryPath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DiskTriageCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("scripts/lib/temp-leak.sh")
            .path
    }()

    // REQ-0230
    @Test("REQ0230 the gate fails and names a new disktriage-* directory")
    func REQ0230_newDirectoryIsAFailureWithItsName() throws {
        let root = try temp.makeDirectory("fake-temp-root")
        try FileManager.default.createDirectory(
            atPath: root + "/disktriage-preexisting",
            withIntermediateDirectories: true
        )
        let before = temp.child("before.txt")
        let after = temp.child("after.txt")

        let result = runBash("""
        set -u
        . '\(Self.libraryPath)'
        temp_leak_list '\(root)' > '\(before)'
        mkdir -p '\(root)/disktriage-new'
        temp_leak_list '\(root)' > '\(after)'
        temp_leak_verdict '\(before)' '\(after)'
        """)

        #expect(result.code == 1, "a new directory is FAIL: \(result.output)")
        #expect(result.output.contains("1 new"), "the count is printed: \(result.output)")
        #expect(result.output.contains("disktriage-new"), "the name is printed: \(result.output)")
    }

    // REQ-0231
    @Test("REQ0231 a pre-existing disktriage-* directory is a warning and is not deleted")
    func REQ0231_preexistingDirectoryIsAWarningOnly() throws {
        let root = try temp.makeDirectory("fake-temp-root")
        let existing = root + "/disktriage-preexisting"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        let before = temp.child("before.txt")
        let after = temp.child("after.txt")

        let result = runBash("""
        set -u
        . '\(Self.libraryPath)'
        temp_leak_list '\(root)' > '\(before)'
        temp_leak_list '\(root)' > '\(after)'
        temp_leak_verdict '\(before)' '\(after)'
        """)

        #expect(result.code == 0, "a pre-existing directory is not this run's failure: \(result.output)")
        #expect(result.output.contains("pre-existing"), "\(result.output)")
        #expect(result.output.contains("PASS"), "\(result.output)")
        #expect(FileManager.default.fileExists(atPath: existing),
                "the gate never deletes a pre-existing directory")
    }

    // REQ-0232
    @Test("REQ0232 only the delta between the before and after snapshots is new")
    func REQ0232_onlyTheDeltaIsNew() throws {
        let root = try temp.makeDirectory("fake-temp-root")
        try FileManager.default.createDirectory(
            atPath: root + "/disktriage-preexisting",
            withIntermediateDirectories: true
        )
        let before = temp.child("before.txt")
        let after = temp.child("after.txt")

        let result = runBash("""
        set -u
        . '\(Self.libraryPath)'
        temp_leak_list '\(root)' > '\(before)'
        mkdir -p '\(root)/disktriage-new'
        temp_leak_list '\(root)' > '\(after)'
        temp_leak_verdict '\(before)' '\(after)'
        """)

        #expect(result.code == 1, "\(result.output)")
        #expect(result.output.contains("disktriage-new"), "\(result.output)")
        #expect(!result.output.contains("disktriage-preexisting"),
                "a directory present before the run is never reported as new: \(result.output)")
    }

    private func runBash(_ script: String) -> (output: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ("cannot run bash: \(error)", -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
