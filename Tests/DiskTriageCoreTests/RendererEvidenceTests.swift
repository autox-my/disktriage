import Foundation
import Testing
import DiskTriageCore

/// P1e: the renderer must show the `Errors (Read)` counter and the kernel
/// evidence the parser now carries, without changing the MiNaH acceptance
/// transcript (which has no `errors` field and no sense/retry fields).
struct RendererEvidenceTests {

    @Test("the IORegistry row shows errors when recorded and keeps MiNaH unchanged")
    func theIORegistryRowShowsErrors() throws {
        let evidence = try decodeFixture("ioreg-and-kernel-evidence.json")
        let tty = Renderer.tty(evidence, classify(evidence))
        #expect(tty.contains("errors 1"), "the ioreg Errors (Read) counter: \(tty)")

        let minah = try decodeFixture("minah.json")
        let minahTTY = Renderer.tty(
            minah,
            classify(minah, context: TriageContext(imageDestination: "/Volumes/Scratch/minah.img"))
        )
        #expect(minahTTY.contains("IORegistry         retries 1,204 · timeouts 3"),
                "an absent errors counter adds no line")
    }

    @Test("the kernel-log evidence line carries the sense key, decimal LBA and retry count")
    func theKernelEvidenceLineIsRendered() throws {
        let signals = try decodeFixture("ioreg-and-kernel-evidence.json")
        let tty = Renderer.tty(signals, classify(signals))

        #expect(tty.contains("sense key 3"), "sense key from the kernel log")
        #expect(tty.contains("LBA 2048"), "the decimal LBA, not 0x800")
        #expect(tty.contains("20 retries"), "the retry count")
        #expect(tty.contains("kernel log"), "labelled as the kernel evidence line")
    }
}

private func decodeFixture(_ name: String) throws -> SignalSet {
    try JSONDecoder.disktriage().decode(SignalSet.self, from: try fixtureData(name))
}
