import Foundation
import Testing
import DiskTriageCore

/// P2b: the FDA state machine and the onboarding wording (diskdoctor.md §7,
/// docs/p0-runbook.md Phase A "Row 7 / 8").
///
/// The errno meanings are the **measured** ones, not the plan's older guess:
/// EPERM (1) is a TCC denial, EACCES (13) means TCC passed and Unix permissions
/// denied, EINVAL (22) means access worked but the read was misaligned.
struct FDAStateTests {

    // REQ-0061: a real read on every run; no probe can never be GRANTED.
    // REQ-0067: the terminal is named.
    // REQ-0068: the grant is called broad.
    @Test("REQ-0064 REQ0061_REQ0067_REQ0068 EPERM is DENIED and names the terminal, the deep link and the broad grant")
    func REQ0064_REQ0061_REQ0067_REQ0068_EPERMIsDeniedAndNamesTheTerminal() {
        let status = FDAStateMachine.evaluate(
            first: .failed(errno: 1, message: "Operation not permitted")
        )

        #expect(status.state == .denied, "EPERM is the TCC denial")
        #expect(!status.tccPassed, "TCC did not pass")

        let message = FDAGuidance.degradedImagingMessage(state: status.state, terminal: "Ghostty")
        let expected = """
          ! raw device access denied (TCC)
            Triage completed without it: verdict still MEDIA.
            Imaging needs Full Disk Access for the process that runs it
            (Ghostty, if you launched this from Ghostty).
            → System Settings open · relaunch required (grant applies at launch)
        """
        #expect(message == expected, "the Appendix transcript, parameterised by the terminal")

        let instructions = FDAGuidance.grantInstructions(
            state: status.state,
            terminal: "Ghostty",
            terminalPath: "/Applications/Ghostty.app"
        )
        let joined = instructions.joined(separator: "\n")
        #expect(joined.contains("Ghostty"), "names the responsible process")
        #expect(joined.contains("/Applications/Ghostty.app"), "names the exact bundle when known")
        #expect(joined.lowercased().contains("broad grant"), "warns that a terminal grant is broad")
        #expect(joined.contains(FDAGuidance.fullDiskAccessDeepLink), "the deep link is exact")
        #expect(joined.contains("relaunch"), "the grant applies at launch")
        #expect(joined.contains("next run"), "re-probing happens on the next run")
    }

    @Test("a successful 4096-byte read is GRANTED; a second success in the same run is VERIFIED")
    func successIsGrantedAndASecondSuccessIsVerified() {
        let once = FDAStateMachine.evaluate(first: .read(bytes: 4096))
        #expect(once.state == .granted, "one successful read grants")
        #expect(once.needsSudo == false, "no sudo needed")

        let twice = FDAStateMachine.evaluate(
            first: .read(bytes: 4096),
            second: .read(bytes: 4096)
        )
        #expect(twice.state == .verified, "two successes in one run verify")
    }

    @Test("REQ0064 EACCES is FDA-granted-looking with a sudo remedy, never a plain failure")
    func REQ0064_EACCESMeansTCCPassedButUnixDenied() {
        let status = FDAStateMachine.evaluate(
            first: .failed(errno: 13, message: "Permission denied")
        )

        #expect(status.state == .granted, "EACCES means TCC passed")
        #expect(status.tccPassed, "TCC passed")
        #expect(status.needsSudo, "Unix permissions need root")
        #expect(status.detail.lowercased().contains("sudo"), "names the remedy")
        #expect(status.detail.lowercased().contains("looks granted"), "not reported as a failure")

        #expect(FDAGuidance.degradedImagingMessage(state: status.state, terminal: "Ghostty").isEmpty,
                "granted access is not a degraded mode")
    }

    @Test("EINVAL means access worked and the read was misaligned")
    func EINVALMeansAccessWorked() {
        let status = FDAStateMachine.evaluate(
            first: .failed(errno: 22, message: "Invalid argument")
        )

        #expect(status.state == .granted, "EINVAL is not a permission failure")
        #expect(status.detail.contains("access worked"), "records the P0 finding")
        #expect(status.needsSudo == false, "no sudo needed")
    }

    @Test("any other errno is UNKNOWN with the errno kept")
    func anotherErrnoIsUnknown() {
        let status = FDAStateMachine.evaluate(first: .failed(errno: 6, message: "Device not configured"))

        #expect(status.state == .unknown, "not a permission verdict")
        #expect(status.detail.contains("6"), "the errno is not thrown away")
        #expect(status.detail.contains("Device not configured"), "the measured text is kept")
    }

    // REQ-0061: no probe, no GRANTED.
    @Test("REQ0061 a probe that never ran is UNKNOWN, never GRANTED")
    func REQ0061_noProbeIsNeverGranted() {
        let status = FDAStateMachine.evaluate(first: .notRun(reason: "no internal disk found"))
        #expect(status.state == .unknown, "an absent probe is not a grant")
        #expect(status.detail.contains("no internal disk found"), "the reason is kept")

        let empty = FDAStateMachine.evaluate(first: .read(bytes: 0))
        #expect(empty.state == .unknown, "a zero-byte read is not evidence of access")
    }

    @Test("a non-terminal responsible app gets the broad-grant warning without the terminal claim")
    func aNonTerminalAppIsDescribedHonestly() {
        let joined = FDAGuidance.grantInstructions(
            state: .denied,
            terminal: "T3 Code (Beta)",
            terminalPath: "/Applications/T3 Code (Beta).app",
            responsibleIsTerminal: false
        ).joined(separator: "\n")

        #expect(!joined.contains("terminal application"), "does not mislabel a host app")
        #expect(joined.lowercased().contains("broad grant"), "still warns about the broad grant")
        #expect(joined.contains("T3 Code (Beta)"), "still names the responsible app")
    }

    @Test("UNKNOWN still tells the user what to grant and that it re-probes next run")
    func unknownStillCarriesTheOnboarding() {
        let instructions = FDAGuidance.grantInstructions(
            state: .unknown,
            terminal: "Ghostty",
            terminalPath: nil
        )
        let joined = instructions.joined(separator: "\n")

        #expect(joined.contains("Ghostty"), "names the terminal")
        #expect(joined.contains(FDAGuidance.fullDiskAccessDeepLink), "deep link")
        #expect(joined.contains("relaunch"), "relaunch note")
        #expect(joined.contains("next run"), "next-run note")
        #expect(FDAGuidance.degradedImagingMessage(state: .unknown, terminal: "Ghostty").contains("could not be verified"),
                "degraded wording distinguishes unknown from denied")
    }
}
