import Foundation
import Testing
import DiskTriageCore

/// The Appendix transcript is the acceptance test for P1 (diskdoctor.md §11):
/// given the MiNaH fixture, the renderer must produce it byte for byte.
struct RendererTests {

    @Test
    func `REQ-0059 the MiNaH tty transcript is byte-for-byte the Appendix`() throws {
        let signals = try fixture("minah.json")
        let verdict = classify(
            signals,
            context: TriageContext(imageDestination: "/Volumes/Scratch/minah.img")
        )
        let expected = String(decoding: try fixtureData("minah.transcript.txt"), as: UTF8.self)
        let actual = Renderer.tty(signals, verdict)

        let difference = firstDifference(expected, actual)
        #expect(difference == nil, "\(difference ?? "")")
    }

    @Test
    func `REQ-0059 --local renders the log window in the supplied zone`() throws {
        let signals = try fixture("minah.json")
        let verdict = classify(
            signals,
            context: TriageContext(imageDestination: "/Volumes/Scratch/minah.img")
        )

        #expect(Renderer.tty(signals, verdict).contains("23:51Z–00:12Z"), "default is UTC")
        let plusOne = Renderer.tty(signals, verdict, timeZone: TimeZone(secondsFromGMT: 3600)!)
        #expect(plusOne.contains("00:51–01:12"), "the supplied zone, not UTC")
    }

    @Test
    func `REQ-0043 the degraded no-FDA block matches the Appendix`() throws {
        let signals = try fixture("minah.json")
        let verdict = classify(signals)
        let expected = String(decoding: try fixtureData("degraded-no-fda.transcript.txt"), as: UTF8.self)
        let actual = Renderer.degradedNoFDA(signals, verdict)

        let difference = firstDifference(expected, actual)
        #expect(difference == nil, "\(difference ?? "")")
    }

    @Test
    func `the JSON render is stable and keys are sorted`() throws {
        let verdict = classify(try fixture("minah.json"))
        let first = Renderer.json(verdict)
        let second = Renderer.json(verdict)

        #expect(first == second, "same verdict, same bytes")
        let keys = ["\"aggravators\"", "\"causes\"", "\"evidence_available\"",
                    "\"evidence_unavailable\"", "\"imaging_offered\"", "\"next\"",
                    "\"unsupported\"", "\"verdict\"", "\"warnings\""]
        let positions = keys.compactMap { first.range(of: $0)?.lowerBound }
        #expect(positions.count == keys.count, "every key is present")
        #expect(positions == positions.sorted(), "keys are sorted")
    }

    @Test
    func `REQ-0049 the tty states that unsupported media is not classified`() throws {
        let signals = try fixture("unsupported-media.json")
        let verdict = classify(signals)
        let tty = Renderer.tty(signals, verdict)

        #expect(tty.contains("UNSUPPORTED"), "the caveat is shown")
        #expect(tty.contains("disktriage image"), "imaging is still offered")
    }

    @Test
    func `REQ-0040 the JSON carries every finding whatever the exit code`() throws {
        let verdict = classify(try fixture("media-and-bridge.json"))
        let json = Renderer.json(verdict)

        #expect(json.contains("\"MEDIA\""), "MEDIA in causes")
        #expect(json.contains("\"BRIDGE\""), "BRIDGE in causes")
        #expect(json.contains("\"code\" : 10"), "exit 10")
    }

    @Test
    func `REQ-0099 the tty says the loss extent is unknown, never a number`() throws {
        let signals = try fixture("minah.json")
        let verdict = classify(
            signals,
            context: TriageContext(imageDestination: "/Volumes/Scratch/minah.img")
        )
        let tty = Renderer.tty(signals, verdict)

        #expect(tty.contains("the real extent of loss is unknown"), "unknown extent")
        #expect(tty.contains("The disk is degrading, not dead."), "not a death sentence")

        let json = Renderer.json(verdict)
        #expect(!json.lowercased().contains("data loss of"), "no loss-size claim")
        #expect(json.range(of: #"[0-9]+\s*(KB|MB|GB|TB)"#, options: .regularExpression) == nil,
                "no predicted loss size")
    }
}

/// Reports the first line that differs, so a transcript failure names the line.
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
