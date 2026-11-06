import Foundation

/// The three-state result of one self-test row. `UNVERIFIABLE` is a finding,
/// never a pass (docs/sdlc.md).
public enum CheckStatus: String, Codable, Sendable, Equatable {
    case pass = "PASS"
    case fail = "FAIL"
    case unverifiable = "UNVERIFIABLE"
}

/// One row of `disktriage check`. `guidance` carries the FDA onboarding block
/// when the row needs it, so the human table and the JSON cannot drift.
public struct CheckRow: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let status: CheckStatus
    public let detail: String
    public let guidance: [String]?

    public init(
        id: String,
        label: String,
        status: CheckStatus,
        detail: String,
        guidance: [String]? = nil
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.detail = detail
        self.guidance = guidance
    }

    enum CodingKeys: String, CodingKey {
        case id, label, status, detail, guidance
    }
}

/// The permissions and tooling self-test (diskdoctor.md §7).
///
/// The exit code is verdict-like and tri-state: any definite FAIL is 1, else
/// any UNVERIFIABLE is 3, else 0. An empty report is 3 — a runner that ran no
/// checks is never a pass.
public struct CheckReport: Equatable, Sendable {
    public let rows: [CheckRow]

    public init(rows: [CheckRow]) {
        self.rows = rows
    }

    public var exitCode: Int {
        if rows.contains(where: { $0.status == .fail }) { return 1 }
        if rows.isEmpty || rows.contains(where: { $0.status == .unverifiable }) { return 3 }
        return 0
    }

    public var verdict: CheckStatus {
        switch exitCode {
        case 0: return .pass
        case 3: return .unverifiable
        default: return .fail
        }
    }

    /// The human table. Presentation only; the JSON reads the same rows.
    public func tty() -> String {
        var lines = [
            pad("CHECK", 33) + pad("STATUS", 14) + "DETAIL",
        ]
        for row in rows {
            lines.append(pad(row.label, 33) + pad(row.status.rawValue, 14) + row.detail)
            for line in row.guidance ?? [] {
                lines.append("    " + line)
            }
        }
        lines.append("")
        lines.append("VERDICT  \(verdict.rawValue) (exit \(exitCode))")
        return lines.joined(separator: "\n")
    }

    /// `--json` output. The summary carries the verdict and the process code;
    /// the checks keep their statuses verbatim.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Summary(report: self))
    }

    private struct Summary: Encodable {
        let exitCode: Int
        let verdict: String
        let checks: [CheckRow]

        init(report: CheckReport) {
            self.exitCode = report.exitCode
            self.verdict = report.verdict.rawValue
            self.checks = report.rows
        }

        enum CodingKeys: String, CodingKey {
            case exitCode = "exit_code"
            case verdict
            case checks
        }
    }
}

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}
