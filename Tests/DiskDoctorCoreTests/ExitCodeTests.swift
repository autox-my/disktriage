import DiskDoctorCore

/// Exit codes and their precedence are a contract from diskdoctor.md §5.
/// The expectations below are transcribed from the plan's table, not derived
/// from the implementation.
@MainActor
func exitCodeTests() {
    test("exit codes match the plan (diskdoctor.md §5)") {
        try expectEqual(ExitCode.noActionableFault.rawValue, 0, "no actionable fault")
        try expectEqual(ExitCode.mediaRisk.rawValue, 10, "media risk")
        try expectEqual(ExitCode.failing.rawValue, 11, "failing")
        try expectEqual(ExitCode.bridgeLinkPower.rawValue, 12, "bridge/link/power")
        try expectEqual(ExitCode.filesystemOnly.rawValue, 13, "filesystem only")
        try expectEqual(ExitCode.insufficientEvidence.rawValue, 20, "insufficient evidence")
        try expectEqual(ExitCode.permissionDenied.rawValue, 21, "permission denied")
        try expectEqual(ExitCode.toolError.rawValue, 30, "tool error")
    }

    test("precedence picks the most severe: 11 > 10 > 12 > 13 > 20 > 0") {
        let all: [ExitCode] = [
            .noActionableFault, .mediaRisk, .failing,
            .bridgeLinkPower, .filesystemOnly, .insufficientEvidence,
        ]
        try expectEqual(ExitCode.mostSevere(all), .failing, "all findings")

        try expectEqual(
            ExitCode.mostSevere([.noActionableFault, .mediaRisk, .bridgeLinkPower, .filesystemOnly, .insufficientEvidence]),
            .mediaRisk, "without failing"
        )
        try expectEqual(
            ExitCode.mostSevere([.bridgeLinkPower, .filesystemOnly, .insufficientEvidence, .noActionableFault]),
            .bridgeLinkPower, "without failing or media"
        )
        try expectEqual(
            ExitCode.mostSevere([.filesystemOnly, .insufficientEvidence, .noActionableFault]),
            .filesystemOnly, "without 11, 10, 12"
        )
        try expectEqual(
            ExitCode.mostSevere([.insufficientEvidence, .noActionableFault]),
            .insufficientEvidence, "without 11, 10, 12, 13"
        )
        try expectEqual(ExitCode.mostSevere([.noActionableFault]), .noActionableFault, "clean")
    }

    test("precedence does not depend on input order") {
        let codes: [ExitCode] = [.filesystemOnly, .failing, .noActionableFault, .bridgeLinkPower]
        try expectEqual(ExitCode.mostSevere(codes), .failing, "forward order")
        try expectEqual(ExitCode.mostSevere(codes.reversed()), .failing, "reverse order")
    }

    test("a verdict outranks a collection failure") {
        try expectEqual(ExitCode.mostSevere([.permissionDenied, .mediaRisk]), .mediaRisk, "denied + media")
        try expectEqual(ExitCode.mostSevere([.toolError, .failing]), .failing, "tool error + failing")
    }

    test("a collection failure is used only when no verdict exists") {
        try expectEqual(ExitCode.mostSevere([.permissionDenied]), .permissionDenied, "denied alone")
        try expectEqual(ExitCode.mostSevere([.permissionDenied, .toolError]), .toolError, "denied + tool error")
    }

    test("no findings is insufficient evidence, never success") {
        try expectEqual(ExitCode.mostSevere([]), .insufficientEvidence, "empty finding list")
    }

    test("Verdict adopts the most severe code") {
        let verdict = Verdict(
            adopting: [.noActionableFault, .mediaRisk, .bridgeLinkPower],
            headline: "degrading, not dead; extent of loss unknown until imaged"
        )
        try expectEqual(verdict.code, .mediaRisk, "verdict.code")
        try expectEqual(verdict.code.rawValue, 10, "verdict.code.rawValue")
    }
}
