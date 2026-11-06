import Testing
import DiskTriageCLI
import DiskTriageGuard

/// The CLI registration only: the guard's own behaviour is tested in
/// DiskTriageGuardTests. Here the command must be real, not "planned".
struct GuardCommandCLITests {

    @Test("guard --help documents the flags and exits 0")
    func helpIsTheGuardHelp() {
        let result = run(arguments: ["guard", "--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--suspend"), "the guard help, not the planned stub")
        #expect(result.stdout.contains("--seconds"))
    }

    @Test("a bad guard flag is a usage error (2), not the planned-command code (30)")
    func badFlagIsUsage() {
        let result = run(arguments: ["guard", "--wat"])
        #expect(result.exitCode == usageExitCode)
        #expect(result.stderr.contains("unknown option"))
    }

    @Test("the guard and CLI agree on the usage code")
    func usageCodesAgree() {
        #expect(guardUsageExitCode == usageExitCode)
    }
}
