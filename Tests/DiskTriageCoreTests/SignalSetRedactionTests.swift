import Foundation
import Testing
import DiskTriageCore

/// `--record` may only commit a redacted SignalSet: the serial is hashed and
/// every measurement is preserved (REQ-0060).
struct SignalSetRedactionTests {

    @Test("redaction hashes the serial and leaves the measurements alone")
    func REQ0060_redactionHashesTheSerial() throws {
        let set = try JSONDecoder.disktriage().decode(SignalSet.self, from: try fixtureData("minah.json"))
        let redacted = set.redacted(serialHash: { "hashed-\($0.count)" })

        #expect(redacted.device?.serial == "hashed-15", "the serial is replaced")
        #expect(redacted.device?.serial != set.device?.serial, "the raw serial is gone")
        #expect(redacted.device?.model == set.device?.model, "the model is not a secret here")
        #expect(redacted.device?.sizeBytes == 320_072_933_376, "size preserved")
        #expect(redacted.smart?.pending == 131, "smart counters preserved")
        #expect(redacted.log?.events?.first?.lba == 2048, "log evidence preserved")
        #expect(redacted.collectedAt == set.collectedAt, "collected_at preserved")
    }

    @Test("a set with no serial is returned unchanged")
    func aSetWithoutASerialIsUnchanged() throws {
        let json = """
        { "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk0", "media": "ssd" } }
        """
        let set = try JSONDecoder.disktriage().decode(SignalSet.self, from: Data(json.utf8))
        #expect(set.redacted(serialHash: { _ in "x" }) == set, "nothing to redact")
    }
}
