import Foundation
import DiskTriageCore

/// One row's probe outcome. The probe decides PASS/FAIL/UNVERIFIABLE; the
/// runner only lays the rows out.
public struct CheckProbe: Equatable, Sendable {
    public let status: CheckStatus
    public let detail: String

    public init(status: CheckStatus, detail: String) {
        self.status = status
        self.detail = detail
    }

    public static func pass(_ detail: String) -> CheckProbe { CheckProbe(status: .pass, detail: detail) }
    public static func fail(_ detail: String) -> CheckProbe { CheckProbe(status: .fail, detail: detail) }
    public static func unverifiable(_ detail: String) -> CheckProbe {
        CheckProbe(status: .unverifiable, detail: detail)
    }
}

/// The tooling rows that need a version.
public enum CheckTool: String, CaseIterable, Sendable, Equatable {
    case smartctl
    case ddrescue
    case ntfsinfo
    case ntfsls
    case ntfscat
    case ntfscluster

    public static let ntfsTools: [CheckTool] = [.ntfsinfo, .ntfsls, .ntfscat, .ntfscluster]
}

/// The process that needs the TCC grant. For a CLI in a terminal that is the
/// terminal application (diskdoctor.md §7, option A).
public struct TerminalIdentity: Equatable, Sendable {
    public let name: String
    public let bundlePath: String?
    /// True for a terminal application. A host app (an IDE or the app that
    /// spawned the CLI) is named but is not called a terminal.
    public let isTerminal: Bool

    public init(name: String, bundlePath: String? = nil, isTerminal: Bool = true) {
        self.name = name
        self.bundlePath = bundlePath
        self.isTerminal = isTerminal
    }

    /// Used when no `.app` ancestor can be identified: still names what the
    /// user must grant, without inventing a terminal name.
    public static let unidentified = TerminalIdentity(
        name: "the terminal application you ran this from",
        bundlePath: nil,
        isTerminal: true
    )
}

/// Every probe the self-test needs. The tests inject a scripted implementation,
/// so no test reads a device, a file or a subprocess.
public protocol CheckProbing: Sendable {
    func runningAsRoot() -> Bool
    func probeRawDevice() -> FDAProbeEvidence
    func removableVolumeAccess() -> CheckProbe
    func tool(_ tool: CheckTool) -> CheckProbe
    func filesystemDrivers() -> CheckProbe
    func unifiedLogReadable() -> CheckProbe
    func mountGuardAvailable() -> CheckProbe
    func sleepPrevention() -> CheckProbe
    func diskArbitrationDaemon() -> CheckProbe
    func terminal() -> TerminalIdentity
}

/// Builds the `disktriage check` table from injected probes. Pure plumbing: no
/// OS calls and no caching.
public struct CheckRunner: Sendable {
    private let probes: any CheckProbing

    public init(probes: any CheckProbing) {
        self.probes = probes
    }

    public func run() -> CheckReport {
        let first = probes.probeRawDevice()
        // A second probe in the same run is what turns GRANTED into VERIFIED;
        // it only makes sense after a successful read.
        let second = first.isSuccessfulRead ? probes.probeRawDevice() : nil
        let fda = FDAStateMachine.evaluate(first: first, second: second)
        let terminal = probes.terminal()

        var rows: [CheckRow] = []
        rows.append(CheckRow(
            id: "root",
            label: "running as root",
            status: .pass,
            detail: probes.runningAsRoot() ? "yes" : "no"
        ))
        rows.append(rawDeviceRow(fda, terminal: terminal))
        rows.append(row(id: "removable-volume", label: "removable volume file access",
                        probe: probes.removableVolumeAccess()))
        rows.append(row(id: "smartctl", label: "smartctl", probe: probes.tool(.smartctl)))
        rows.append(row(id: "ddrescue", label: "ddrescue", probe: probes.tool(.ddrescue)))
        rows.append(ntfsToolsRow())
        rows.append(row(id: "filesystem-drivers", label: "third-party FS drivers",
                        probe: probes.filesystemDrivers()))
        rows.append(row(id: "unified-log", label: "unified log readable",
                        probe: probes.unifiedLogReadable()))
        rows.append(row(id: "mount-guard", label: "mount guard available",
                        probe: probes.mountGuardAvailable()))
        rows.append(row(id: "sleep-prevention", label: "sleep prevention (caffeinate)",
                        probe: probes.sleepPrevention()))
        rows.append(row(id: "diskarbitrationd", label: "diskarbitrationd state",
                        probe: probes.diskArbitrationDaemon()))

        return CheckReport(rows: rows)
    }

    private func rawDeviceRow(_ status: FDAStatus, terminal: TerminalIdentity) -> CheckRow {
        switch status.state {
        case .granted, .verified:
            return CheckRow(
                id: "raw-read",
                label: "raw device read",
                status: .pass,
                detail: "\(status.state.rawValue) — \(status.detail)"
            )
        case .denied:
            return CheckRow(
                id: "raw-read",
                label: "raw device read",
                status: .fail,
                detail: "DENIED — \(status.detail)",
                guidance: FDAGuidance.grantInstructions(
                    state: .denied,
                    terminal: terminal.name,
                    terminalPath: terminal.bundlePath,
                    responsibleIsTerminal: terminal.isTerminal
                )
            )
        case .unknown:
            return CheckRow(
                id: "raw-read",
                label: "raw device read",
                status: .unverifiable,
                detail: "UNKNOWN — \(status.detail)",
                guidance: FDAGuidance.grantInstructions(
                    state: .unknown,
                    terminal: terminal.name,
                    terminalPath: terminal.bundlePath,
                    responsibleIsTerminal: terminal.isTerminal
                )
            )
        }
    }

    private func ntfsToolsRow() -> CheckRow {
        let results = CheckTool.ntfsTools.map { ($0, probes.tool($0)) }
        let found = results.filter { $0.1.status == .pass }
        let missing = results.filter { $0.1.status != .pass }

        if missing.isEmpty {
            let versions = found.map { "\($0.0.rawValue) \($0.1.detail)" }
            return CheckRow(
                id: "ntfs-3g",
                label: "ntfs-3g tools",
                status: .pass,
                detail: versions.joined(separator: " · ")
            )
        }
        // The row repeats each tool's own detail, which names the prefix and
        // directories searched: "missing ntfsls" is only honest when that path
        // list is not the one inspect found the binary under.
        let searched = missing
            .map { "\($0.0.rawValue) (\($0.1.detail))" }
            .joined(separator: "; ")
        if found.isEmpty {
            return CheckRow(
                id: "ntfs-3g",
                label: "ntfs-3g tools",
                status: .unverifiable,
                detail: "not installed: \(searched); NTFS inspection unavailable"
            )
        }
        return CheckRow(
            id: "ntfs-3g",
            label: "ntfs-3g tools",
            status: .fail,
            detail: "missing \(searched)"
        )
    }

    private func row(id: String, label: String, probe: CheckProbe) -> CheckRow {
        CheckRow(id: id, label: label, status: probe.status, detail: probe.detail)
    }
}
