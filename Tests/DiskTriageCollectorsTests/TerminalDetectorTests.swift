import Foundation
import Testing
import DiskTriageCore
@testable import DiskTriageCollectors

/// P2b: the responsible process for a CLI is its terminal (diskdoctor.md §7,
/// option A). These tests inject the parent chain; nothing reads a process.
struct TerminalDetectorTests {

    @Test("an ancestor inside a .app names the terminal and its bundle")
    func appBundleAncestorNamesTheTerminal() {
        let identity = TerminalDetector.identity(
            ancestors: [
                "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                "/bin/zsh",
                "/usr/sbin/sshd",
            ],
            termProgram: nil
        )

        #expect(identity.name == "Ghostty", "the .app name")
        #expect(identity.bundlePath == "/Applications/Ghostty.app", "the exact bundle to add")
    }

    @Test("the nearest .app ancestor wins")
    func nearestAppAncestorWins() {
        let identity = TerminalDetector.identity(
            ancestors: [
                "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            ],
            termProgram: nil
        )
        #expect(identity.name == "Ghostty", "the parent is the terminal, not the IDE above it")
    }

    @Test("TERM_PROGRAM is used when no ancestor is inside an app bundle")
    func termProgramMapsToTheApplicationName() {
        let cases = [
            ("Apple_Terminal", "Terminal"),
            ("iTerm.app", "iTerm"),
            ("ghostty", "Ghostty"),
            ("vscode", "Visual Studio Code"),
            ("WezTerm", "WezTerm"),
        ]
        for (termProgram, expected) in cases {
            let identity = TerminalDetector.identity(ancestors: ["/bin/zsh"], termProgram: termProgram)
            #expect(identity.name == expected, "\(termProgram) names \(expected)")
            #expect(identity.bundlePath == nil, "no bundle was observed")
        }
    }

    @Test("a non-terminal host app is named but not called a terminal")
    func aNonTerminalAppIsNotCalledATerminal() {
        let identity = TerminalDetector.identity(
            ancestors: ["/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)"],
            termProgram: nil
        )
        #expect(identity.name == "T3 Code (Beta)", "the responsible app")
        #expect(identity.isTerminal == false, "it is not a terminal application")
    }

    @Test("a known terminal bundle is a terminal even without TERM_PROGRAM")
    func aKnownTerminalBundleIsATerminal() {
        let identity = TerminalDetector.identity(
            ancestors: ["/Applications/Ghostty.app/Contents/MacOS/ghostty"],
            termProgram: nil
        )
        #expect(identity.isTerminal, "Ghostty is a terminal")
    }

    @Test("no evidence is an honest fallback, not an invented terminal")
    func noEvidenceFallsBack() {
        let identity = TerminalDetector.identity(ancestors: ["/bin/zsh"], termProgram: nil)
        #expect(identity == .unidentified, "no terminal name is invented")
        #expect(identity.name.contains("terminal"), "still says what kind of process needs the grant")
    }
}
