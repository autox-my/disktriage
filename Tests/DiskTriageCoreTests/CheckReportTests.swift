import Foundation
import Testing
import DiskTriageCore

/// P2b: the three-state self-test report. UNVERIFIABLE is never PASS, and a
/// definite FAIL outranks it (the project's tri-state, docs/sdlc.md).
struct CheckReportTests {

    @Test("all rows PASS is exit 0")
    func allPassIsZero() {
        let report = CheckReport(rows: [
            CheckRow(id: "root", label: "running as root", status: .pass, detail: "no"),
            CheckRow(id: "raw-read", label: "raw device read", status: .pass, detail: "GRANTED"),
        ])

        #expect(report.exitCode == 0, "nothing failed")
        #expect(report.verdict == .pass, "PASS")
        #expect(report.tty().contains("running as root"), "the row is shown")
        #expect(report.tty().contains("raw device read"), "the row is shown")
        #expect(report.tty().contains("PASS"), "the status is shown")
    }

    @Test("a definite FAIL exits 1 and outranks UNVERIFIABLE")
    func aFailOutranksUnverifiable() {
        let report = CheckReport(rows: [
            CheckRow(id: "raw-read", label: "raw device read", status: .fail, detail: "DENIED"),
            CheckRow(id: "smartctl", label: "smartctl", status: .unverifiable, detail: "not found"),
        ])

        #expect(report.exitCode == 1, "a definite finding wins")
        #expect(report.verdict == .fail, "FAIL")
    }

    // A skipped check is never a pass: UNVERIFIABLE alone is exit 3.
    @Test("UNVERIFIABLE alone is exit 3, never 0")
    func unverifiableAloneIsThree() {
        let report = CheckReport(rows: [
            CheckRow(id: "raw-read", label: "raw device read", status: .pass, detail: "GRANTED"),
            CheckRow(id: "ntfs", label: "ntfs-3g tools", status: .unverifiable, detail: "not installed"),
        ])

        #expect(report.exitCode == 3, "an unverifiable row blocks a pass")
        #expect(report.verdict == .unverifiable, "UNVERIFIABLE")
        #expect(report.tty().contains("UNVERIFIABLE"), "the status is not disguised")
    }

    @Test("an empty report is UNVERIFIABLE, never a pass")
    func anEmptyReportFailsClosed() {
        let report = CheckReport(rows: [])
        #expect(report.exitCode == 3, "a runner that ran no checks is not a pass")
        #expect(report.verdict == .unverifiable, "UNVERIFIABLE")
    }

    // REQ-0061: no probe, no grant; the report keeps the state in the detail.
    @Test("REQ0061 JSON carries every row and the verdict, with UNVERIFIABLE intact")
    func REQ0061_jsonCarriesTheVerdict() throws {
        let report = CheckReport(rows: [
            CheckRow(id: "root", label: "running as root", status: .pass, detail: "no"),
            CheckRow(
                id: "raw-read",
                label: "raw device read",
                status: .unverifiable,
                detail: "UNKNOWN: the probe did not run",
                guidance: ["Full Disk Access could not be verified for Ghostty."]
            ),
        ])

        let object = try #require(
            try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        )
        #expect(object["exit_code"] as? Int == 3, "the JSON verdict is the exit code")
        #expect(object["verdict"] as? String == "UNVERIFIABLE", "never PASS")
        let checks = try #require(object["checks"] as? [[String: Any]], "checks array")
        #expect(checks.count == 2, "every row is present")
        let raw = try #require(checks.first { $0["id"] as? String == "raw-read" }, "the raw row")
        #expect(raw["status"] as? String == "UNVERIFIABLE", "the row status is unchanged")
        let guidance = try #require(raw["guidance"] as? [String], "onboarding guidance travels with the row")
        #expect(guidance.first?.contains("Ghostty") == true, "the terminal is named")
    }
}
