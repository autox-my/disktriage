import Foundation
import DiskTriageCore
import DiskTriageCollectors

/// `disktriage check`: the permissions and tooling self-test (diskdoctor.md
/// §7). The probes are injected; the default is the live implementation.
///
/// Exit codes are the project's tri-state: 0 every row PASS, 1 a definite
/// FAIL, 3 anything UNVERIFIABLE. Usage errors use the CLI's existing code.
public func runCheck(
    arguments: [String],
    probes: any CheckProbing = LiveCheckProbes()
) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return CLIResult(stdout: checkUsage, stderr: "", exitCode: 0)
    }

    var asJSON = false
    for argument in arguments {
        switch argument {
        case "--json":
            asJSON = true
        default:
            return CLIResult(
                stdout: "",
                stderr: "disktriage: unknown option '\(argument)'\n"
                    + "usage: disktriage check [--json]\n",
                exitCode: usageExitCode
            )
        }
    }

    let report = CheckRunner(probes: probes).run()

    if asJSON {
        do {
            let data = try report.jsonData()
            return CLIResult(
                stdout: String(decoding: data, as: UTF8.self) + "\n",
                stderr: "",
                exitCode: Int32(report.exitCode)
            )
        } catch {
            return CLIResult(
                stdout: "",
                stderr: "disktriage: cannot render the self-test JSON: \(error)\n",
                exitCode: 30
            )
        }
    }

    return CLIResult(
        stdout: report.tty() + "\n",
        stderr: "",
        exitCode: Int32(report.exitCode)
    )
}

private let checkUsage = "usage: disktriage check [--json]\n"
    + "\n"
    + "Runs the permissions and tooling self-test: whether this process is root,\n"
    + "the Full Disk Access probe on the internal disk, removable-volume access,\n"
    + "smartctl, ddrescue, the ntfs-3g tools, third-party filesystem drivers, the\n"
    + "unified log, the DiskArbitration mount guard, caffeinate and\n"
    + "diskarbitrationd.\n"
    + "\n"
    + "Exit 0 when every row PASSes, 1 on a definite FAIL, 3 when any row is\n"
    + "UNVERIFIABLE. Nothing is cached; the next run re-probes.\n"
