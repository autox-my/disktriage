import Foundation
import Testing
import DiskTriageTestSupport

/// The gate's native leak guard, driven through the shipped
/// `scripts/lib/native-leak.sh` on fake scan files. It never looks at a real
/// attached image.
struct NativeLeakGuardTests {
    private let temp = TempDir()

    private static let libraryPath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DiskTriageCLITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("scripts/lib/native-leak.sh")
            .path
    }()

    // REQ-0276, REQ-0277, REQ-0278
    @Test("REQ0276_REQ0277_REQ0278 a leaked image or mountpoint fails the native leak guard")
    func REQ0276_REQ0277_REQ0278_nativeLeakGuardBites() throws {
        let clean = temp.child("clean.txt")
        let image = temp.child("image.txt")
        let mount = temp.child("mount.txt")
        let unverifiable = temp.child("unverifiable.txt")
        try Data("CLEAN\n".utf8).write(to: URL(fileURLWithPath: clean))
        try Data("image /tmp/disktriage-tests-abc/leaked.img\n".utf8)
            .write(to: URL(fileURLWithPath: image))
        try Data("mount /dev/disk9s1 on /tmp/disktriage-mount-abc (exfat, read-only)\n".utf8)
            .write(to: URL(fileURLWithPath: mount))
        try Data("UNVERIFIABLE  hdiutil not found\n".utf8)
            .write(to: URL(fileURLWithPath: unverifiable))

        func verdict(_ file: String) -> (output: String, code: Int32) {
            runBash("""
            set -u
            . '\(Self.libraryPath)'
            native_leak_verdict '\(file)'
            """)
        }

        let pass = verdict(clean)
        #expect(pass.code == 0, "a clean scan passes: \(pass.output)")
        #expect(pass.output.contains("PASS"))

        let leakedImage = verdict(image)
        #expect(leakedImage.code == 1, "an attached image fails: \(leakedImage.output)")
        #expect(leakedImage.output.contains("leaked.img"), "the image is named")

        let leakedMount = verdict(mount)
        #expect(leakedMount.code == 1, "a mountpoint fails: \(leakedMount.output)")
        #expect(leakedMount.output.contains("disktriage-mount-abc"), "the mountpoint is named")

        let grey = verdict(unverifiable)
        #expect(grey.code == 3, "a scan that cannot run is UNVERIFIABLE, not a pass: \(grey.output)")
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
