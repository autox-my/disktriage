import Foundation
import Testing
import DiskTriageCLI

/// End-to-end tests through the library seam `run(arguments:readFile:now:)`:
/// no hardware, no live collection, only recorded SignalSets.
struct CLITests {

    // REQ-0057, REQ-0058, REQ-0059
    @Test
    func `REQ0057_REQ0058_REQ0059 triage --from puts the MiNaH transcript on stdout and exits 10`() throws {
        let result = run(arguments: ["triage", "--from", fixturePath("minah.json")])
        let expected = String(
            decoding: try Data(contentsOf: URL(fileURLWithPath: fixturePath("minah.transcript.txt"))),
            as: UTF8.self
        )

        let difference = firstDifference(expected, result.stdout)
        #expect(difference == nil, "\(difference ?? "")")
        #expect(result.exitCode == 10, "the plan's MiNaH exit code")
        #expect(!result.stderr.isEmpty, "progress goes to stderr")
        #expect(!result.stdout.contains("disktriage: reading"), "no progress on stdout")
    }

    // REQ-0057, REQ-0058
    @Test
    func `REQ0057_REQ0058 --json prints the same verdict as JSON on stdout and keeps progress on stderr`() throws {
        let result = run(arguments: ["triage", "--from", fixturePath("minah.json"), "--json"])

        #expect(result.exitCode == 10, "the exit code does not depend on --json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            "stdout is valid JSON"
        )
        let verdict = try #require(object["verdict"] as? [String: Any], "verdict object")
        #expect(verdict["code"] as? Int == 10, "same code as the tty exit")
        #expect(result.stderr.contains("reading"), "progress is on stderr")
        #expect(!result.stdout.contains("disktriage: reading"), "progress is not in the JSON")
    }

    @Test
    func `every fixture exits with the code recorded in expectations.json`() throws {
        let expectations = try JSONDecoder().decode(
            [String: ExpectedVerdict].self,
            from: try Data(contentsOf: URL(fileURLWithPath: fixturePath("expectations.json")))
        )
        #expect(!expectations.isEmpty, "the fixture table is not empty")

        for (name, expected) in expectations {
            let result = run(arguments: ["triage", "--from", fixturePath(name)])
            #expect(result.exitCode == Int32(expected.exitCode), "\(name): exit code")
            #expect(!result.stdout.isEmpty, "\(name): the verdict is on stdout")
        }
    }

    @Test
    func `malformed JSON exits 30 with empty stdout, never a verdict`() {
        let result = run(
            arguments: ["triage", "--from", "broken.json"],
            readFile: { _ in Data("{ not json".utf8) }
        )

        #expect(result.exitCode == 30, "a tool error, not a verdict")
        #expect(result.stdout.isEmpty, "no verdict was formed")
        #expect(result.stderr.contains("malformed"), "the reason is on stderr")
    }

    @Test
    func `an unreadable file exits 30 with empty stdout`() {
        let result = run(
            arguments: ["triage", "--from", "missing.json"],
            readFile: { path in
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
            }
        )

        #expect(result.exitCode == 30, "a tool error, not a verdict")
        #expect(result.stdout.isEmpty, "no verdict was formed")
        #expect(result.stderr.contains("cannot read"), "the reason is on stderr")
    }

    @Test
    func `triage without a disk or --from is a usage error`() {
        let result = run(arguments: ["triage"])

        #expect(result.exitCode == 2, "nothing names a disk to collect")
        #expect(result.stdout.isEmpty, "no verdict")
        #expect(result.stderr.contains("disk"), "names the missing disk")
        #expect(result.stderr.contains("--from"), "names the recorded input")
    }

    @Test
    func `unknown commands and flags are usage errors, not verdicts`() {
        let command = run(arguments: ["frobnicate"])
        #expect(command.exitCode == 2, "unknown command")
        #expect(command.stdout.isEmpty)
        #expect(command.stderr.contains("unknown command"))

        let flag = run(arguments: ["triage", "--from", fixturePath("minah.json"), "--wat"])
        #expect(flag.exitCode == 2, "unknown flag")
        #expect(flag.stdout.isEmpty)
        #expect(flag.stderr.contains("--wat"))

        let value = run(arguments: ["triage", "--from"])
        #expect(value.exitCode == 2, "--from without a path")
        #expect(value.stdout.isEmpty)
    }

    @Test
    func `--help and command --help exit 0 with no side effects`() {
        for arguments in [[], ["--help"], ["help"], ["triage", "--help"],
                          ["triage", "--help", "--from", "/does/not/exist"]] {
            let result = run(arguments: arguments)
            #expect(result.exitCode == 0, "\(arguments): help exits 0")
            #expect(!result.stdout.isEmpty, "\(arguments): help is on stdout")
            #expect(result.stderr.isEmpty, "\(arguments): help has no stderr")
        }

        for command in ["image", "inspect", "copy", "check", "guard", "list"] {
            let result = run(arguments: [command, "--help"])
            #expect(result.exitCode == 0, "\(command) --help exits 0")
            #expect(result.stderr.isEmpty, "\(command) --help has no stderr")
        }
    }

    @Test
    func `planned commands are not implemented and exit 30`() {
        for command in ["copy"] {
            let result = run(arguments: [command])
            #expect(result.exitCode == 30, "\(command): tool error, not a verdict")
            #expect(result.stdout.isEmpty, "\(command): nothing on stdout")
            #expect(result.stderr.contains("not implemented yet (planned P2/P3)"),
                    "\(command): names the plan phase")
        }
    }
}

private struct ExpectedVerdict: Decodable {
    let exitCode: Int

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
    }
}

func fixturePath(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCLITests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/\(name)")
        .path
}

private func firstDifference(_ expected: String, _ actual: String) -> String? {
    if expected == actual { return nil }
    let expectedLines = expected.components(separatedBy: "\n")
    let actualLines = actual.components(separatedBy: "\n")
    let count = max(expectedLines.count, actualLines.count)
    for index in 0..<count {
        let wanted = index < expectedLines.count ? expectedLines[index] : "<missing>"
        let got = index < actualLines.count ? actualLines[index] : "<missing>"
        if wanted != got {
            return "line \(index + 1): expected \(String(reflecting: wanted)), got \(String(reflecting: got))"
        }
    }
    return "differs only in trailing bytes"
}
