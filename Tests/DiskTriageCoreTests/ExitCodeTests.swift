import DiskTriageCore
import Testing

/// Exit codes and their precedence are a contract from diskdoctor.md §5.
/// The expectations below are transcribed from the plan's table, not derived
/// from the implementation.
struct ExitCodeTests {
    @Test("exit codes match the plan (diskdoctor.md §5)")
    func exitCodesMatchThePlan() {
        #expect(ExitCode.noActionableFault.rawValue == 0, "no actionable fault")
        #expect(ExitCode.mediaRisk.rawValue == 10, "media risk")
        #expect(ExitCode.failing.rawValue == 11, "failing")
        #expect(ExitCode.bridgeLinkPower.rawValue == 12, "bridge/link/power")
        #expect(ExitCode.filesystemOnly.rawValue == 13, "filesystem only")
        #expect(ExitCode.insufficientEvidence.rawValue == 20, "insufficient evidence")
        #expect(ExitCode.permissionDenied.rawValue == 21, "permission denied")
        #expect(ExitCode.toolError.rawValue == 30, "tool error")
    }

    @Test("precedence picks the most severe: 11 > 10 > 12 > 13 > 20 > 0")
    func REQ0038_precedencePicksTheMostSevere() {
        let all: [ExitCode] = [
            .noActionableFault, .mediaRisk, .failing,
            .bridgeLinkPower, .filesystemOnly, .insufficientEvidence,
        ]
        #expect(ExitCode.mostSevere(all) == .failing, "all findings")

        #expect(
            ExitCode.mostSevere([.noActionableFault, .mediaRisk, .bridgeLinkPower, .filesystemOnly, .insufficientEvidence]) == .mediaRisk,
            "without failing"
        )
        #expect(
            ExitCode.mostSevere([.bridgeLinkPower, .filesystemOnly, .insufficientEvidence, .noActionableFault]) == .bridgeLinkPower,
            "without failing or media"
        )
        #expect(
            ExitCode.mostSevere([.filesystemOnly, .insufficientEvidence, .noActionableFault]) == .filesystemOnly,
            "without 11, 10, 12"
        )
        #expect(
            ExitCode.mostSevere([.insufficientEvidence, .noActionableFault]) == .insufficientEvidence,
            "without 11, 10, 12, 13"
        )
        #expect(ExitCode.mostSevere([.noActionableFault]) == .noActionableFault, "clean")
    }

    @Test("precedence does not depend on input order")
    func REQ0038_precedenceDoesNotDependOnInputOrder() {
        let codes: [ExitCode] = [.filesystemOnly, .failing, .noActionableFault, .bridgeLinkPower]
        #expect(ExitCode.mostSevere(codes) == .failing, "forward order")
        #expect(ExitCode.mostSevere(codes.reversed()) == .failing, "reverse order")
    }

    @Test("a verdict outranks a collection failure")
    func REQ0041_aVerdictOutranksACollectionFailure() {
        #expect(ExitCode.mostSevere([.permissionDenied, .mediaRisk]) == .mediaRisk, "denied + media")
        #expect(ExitCode.mostSevere([.toolError, .failing]) == .failing, "tool error + failing")
    }

    @Test("a collection failure is used only when no verdict exists")
    func REQ0036_REQ0037_aCollectionFailureIsUsedOnlyWhenNoVerdictExists() {
        #expect(ExitCode.mostSevere([.permissionDenied]) == .permissionDenied, "denied alone")
        #expect(ExitCode.mostSevere([.permissionDenied, .toolError]) == .toolError, "denied + tool error")
    }

    @Test("no findings is insufficient evidence, never success")
    func REQ0035_noFindingsIsInsufficientEvidence() {
        #expect(ExitCode.mostSevere([]) == .insufficientEvidence, "empty finding list")
    }

    @Test("Verdict adopts the most severe code")
    func REQ0038_verdictAdoptsTheMostSevereCode() {
        let verdict = Verdict(
            adopting: [.noActionableFault, .mediaRisk, .bridgeLinkPower],
            headline: "degrading, not dead; extent of loss unknown until imaged"
        )
        #expect(verdict.code == .mediaRisk, "verdict.code")
        #expect(verdict.code.rawValue == 10, "verdict.code.rawValue")
    }
}
