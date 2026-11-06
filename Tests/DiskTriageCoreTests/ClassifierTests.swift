import Foundation
import Testing
import DiskTriageCore

/// The classifier is a pure function over a `SignalSet` (diskdoctor.md §3, §5).
/// Expectations are transcribed from the plan's §5 rules and §11 table, never
/// recomputed the way the classifier computes them.
struct ClassifierTests {

    // MARK: - MEDIA and confidence

    @Test
    func `REQ-0025 MiNaH is MEDIA at high confidence because two sources agree`() throws {
        let verdict = classify(try fixture("minah.json"))

        let media = try #require(cause(.media, in: verdict), "MEDIA cause")
        #expect(media.confidence == .high, "SMART and the kernel log agree")
        #expect(media.sources == [.smart, .kernelLog], "counted sources")
        #expect(verdict.code == .mediaRisk, "exit 10")
        #expect(verdict.code.rawValue == 10, "exit 10")
    }

    @Test
    func `REQ-0028 pending, reallocated and uncorrectable are one source, not three`() throws {
        let set = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "sata" },
          "smart": { "status": "ok", "pending": 131, "reallocated": 14,
                     "uncorrectable": 2, "history": null }
        }
        """)

        let verdict = classify(set)
        let media = try #require(cause(.media, in: verdict), "MEDIA cause")
        #expect(media.sources == [.smart], "one source")
        #expect(media.confidence == .medium, "one strong source is medium, never high")
        #expect(verdict.code == .mediaRisk, "exit 10")
    }

    @Test
    func `REQ-0029 I/O statistics are displayed but not counted until P0 validates them`() throws {
        let unvalidated = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "sata" },
          "smart": { "status": "ok", "pending": 0, "reallocated": 5,
                     "uncorrectable": 0, "history": null },
          "io": { "status": "ok", "retries": 9, "timeouts": 0 }
        }
        """)
        let unvalidatedVerdict = classify(unvalidated)
        let unvalidatedMedia = try #require(cause(.media, in: unvalidatedVerdict), "MEDIA cause")
        #expect(unvalidatedMedia.sources == [.smart], "I/O is not a source by default")
        #expect(unvalidatedMedia.confidence == .low, "one weak source")

        let validated = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "sata" },
          "smart": { "status": "ok", "pending": 0, "reallocated": 5,
                     "uncorrectable": 0, "history": null },
          "io": { "status": "ok", "retries": 9, "timeouts": 0, "p0_validated": true }
        }
        """)
        let validatedVerdict = classify(validated)
        let validatedMedia = try #require(cause(.media, in: validatedVerdict), "MEDIA cause")
        #expect(validatedMedia.sources == [.smart, .ioStatistics], "P0 validated the counters")
        #expect(validatedMedia.confidence == .medium, "two weak sources corroborate")
    }

    // REQ-0029: the real Phase C signal is Errors (Read), not Retries, and the
    // P0 flag stays off until the counters are validated.
    @Test
    func `REQ-0029 an Errors (Read) delta alone does not raise confidence while P0 is off`() throws {
        let set = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "sata" },
          "smart": { "status": "ok", "pending": 0, "reallocated": 5,
                     "uncorrectable": 0, "history": null },
          "io": { "status": "ok", "retries": 0, "errors": 1 }
        }
        """)
        let verdict = classify(set)
        let media = try #require(cause(.media, in: verdict), "MEDIA cause")
        #expect(media.sources == [.smart], "the unvalidated I/O counter is not a source")
        #expect(media.confidence == .low, "one weak source")
    }

    @Test
    func `REQ-0018 a null history never fires the rising-reallocated rule`() throws {
        let set = try fixture("stable-reallocated.json")
        let verdict = classify(set)
        let media = try #require(cause(.media, in: verdict), "MEDIA cause")

        #expect(set.smart?.history == nil, "first sight of the drive")
        #expect(media.confidence == .low, "stable and no history is weak evidence")
        #expect(verdict.code == .noActionableFault, "exit 0, not 10")
        #expect(verdict.code.rawValue == 0, "exit 0, not 10")
    }

    @Test
    func `REQ-0039 a low-confidence MEDIA exits 0 with a warning`() throws {
        let verdict = classify(try fixture("stable-reallocated.json"))
        let media = try #require(cause(.media, in: verdict), "MEDIA cause")

        #expect(media.confidence == .low, "stable reallocated=5")
        #expect(verdict.code == .noActionableFault, "exit 0")
        #expect(verdict.warnings.isEmpty == false, "the warning is present")
    }

    // MARK: - Exit codes and precedence

    @Test
    func `REQ-0026 one strong symptom is medium confidence, not high`() throws {
        let set = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "usb" },
          "smart": { "status": "ok", "pending": 0, "reallocated": 0,
                     "uncorrectable": 0, "history": null },
          "symptoms": { "source": "user", "clicking": true }
        }
        """)

        let verdict = classify(set)
        let head = try #require(cause(.head, in: verdict), "HEAD cause")
        #expect(head.sources == [.userSymptom], "clicking is one source")
        #expect(head.confidence == .medium, "one strong source")
    }

    @Test
    func `REQ-0038 precedence keeps 11 above 10 when HEAD and MEDIA both apply`() throws {
        let set = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "usb" },
          "smart": { "status": "ok", "pending": 8, "reallocated": 0,
                     "uncorrectable": 0, "history": null },
          "symptoms": { "source": "user", "clicking": true }
        }
        """)

        let verdict = classify(set)
        #expect(cause(.head, in: verdict) != nil, "HEAD cause")
        #expect(cause(.media, in: verdict) != nil, "MEDIA cause")
        #expect(verdict.code == .failing, "exit 11 wins")
        #expect(verdict.code.rawValue == 11, "exit 11 wins")
    }

    @Test
    func `REQ-0030 a clean drive is 'no actionable fault found', never 'healthy'`() throws {
        let verdict = classify(try fixture("clean.json"))

        #expect(verdict.code == .noActionableFault, "exit 0")
        #expect(verdict.causes.isEmpty, "no cause to report")
        #expect(verdict.headline.lowercased().contains("no actionable fault"), "headline")
        #expect(!verdict.headline.lowercased().contains("healthy"), "never healthy")
        #expect(!verdict.headline.lowercased().contains("safe"), "never safe")
    }

    @Test
    func `REQ-0035 all collectors timing out is UNKNOWN, not a zero and not a crash`() throws {
        let verdict = classify(try fixture("all-timeout.json"))

        #expect(verdict.code == .insufficientEvidence, "exit 20")
        #expect(verdict.code.rawValue == 20, "exit 20")
        let unknown = try #require(cause(.unknown, in: verdict), "UNKNOWN cause")
        #expect(unknown.confidence == .low, "no usable signal")
        #expect(!verdict.headline.isEmpty, "the verdict says why")
    }

    @Test
    func `REQ-0036 SMART denied and not root exits 21 only when no verdict exists`() throws {
        let verdict = classify(try fixture("smart-denied-not-root.json"))

        #expect(verdict.code == .permissionDenied, "exit 21")
        #expect(verdict.code.rawValue == 21, "exit 21")
        #expect(verdict.causes.isEmpty, "no verdict can be formed")
    }

    @Test
    func `REQ-0041 a denied permission is a status, not the verdict, when a verdict exists`() throws {
        let set = try fixture("minah.json")
        #expect(set.permissions?.rawRead == .denied, "raw read denied")

        let verdict = classify(set)
        #expect(verdict.code == .mediaRisk, "the MEDIA verdict outranks the permission failure")
    }

    // MARK: - The other branches

    @Test
    func `REQ-0033 a hidden SMART with no other signal is BRIDGE suspicion`() throws {
        let verdict = classify(try fixture("bridge-hides-smart.json"))

        let bridge = try #require(cause(.bridge, in: verdict), "BRIDGE cause")
        #expect(bridge.confidence == .low, "circumstantial")
        #expect(verdict.code == .bridgeLinkPower, "exit 12")
        #expect(verdict.code.rawValue == 12, "exit 12")
    }

    @Test
    func `REQ-0031 a kernel medium error survives a hidden SMART and reaches MEDIA medium`() throws {
        let verdict = classify(try fixture("bridge-hides-smart-log.json"))

        let media = try #require(cause(.media, in: verdict), "MEDIA cause")
        #expect(media.confidence == .medium, "the log is one strong source")
        #expect(verdict.code == .mediaRisk, "exit 10")
    }

    @Test
    func `REQ-0032 resets plus clicking is HEAD, exit 11`() throws {
        let verdict = classify(try fixture("head-clicking.json"))

        let head = try #require(cause(.head, in: verdict), "HEAD cause")
        #expect(head.confidence >= .medium, "a user symptom is strong")
        #expect(verdict.code == .failing, "exit 11")
        #expect(verdict.code.rawValue == 11, "exit 11")
    }

    @Test
    func `REQ-0034 filesystem-only damage exits 13`() throws {
        let verdict = classify(try fixture("filesystem-only.json"))

        #expect(cause(.filesystem, in: verdict) != nil, "FILESYSTEM cause")
        #expect(verdict.code == .filesystemOnly, "exit 13")
        #expect(verdict.code.rawValue == 13, "exit 13")
    }

    @Test
    func `REQ-0049 unsupported media is not classified but imaging stays offered`() throws {
        let verdict = classify(try fixture("unsupported-media.json"))

        #expect(verdict.code == .insufficientEvidence, "exit 20")
        #expect(verdict.causes.isEmpty, "no classification")
        #expect(verdict.unsupportedNote != nil, "UNSUPPORTED note")
        #expect(verdict.imagingOffered, "imaging remains available")
    }

    @Test
    func `REQ-0045 an inconclusive result does not block imaging`() throws {
        #expect(classify(try fixture("all-timeout.json")).imagingOffered, "timeout")
    }

    @Test
    func `REQ-0040 two faults keep both findings in the JSON whatever the exit code`() throws {
        let verdict = classify(try fixture("media-and-bridge.json"))

        #expect(cause(.media, in: verdict) != nil, "MEDIA finding")
        #expect(cause(.bridge, in: verdict) != nil, "BRIDGE finding")
        #expect(verdict.code == .mediaRisk, "10 outranks 12")
        #expect(verdict.code.rawValue == 10, "10 outranks 12")
    }

    @Test
    func `REQ-0040 a clean exit still reports the third-party driver aggravator`() throws {
        let set = try decode("""
        {
          "schema_version": 1, "collected_at": "2026-11-06T00:14:02Z",
          "device": { "status": "ok", "bsd": "disk9", "media": "hdd", "bus": "sata" },
          "smart": { "status": "ok", "pending": 0, "reallocated": 0,
                     "uncorrectable": 0, "history": null },
          "fs": { "status": "ok", "type": "ntfs", "mounted": false, "readable": true },
          "drivers": { "status": "ok", "items": [
            { "path": "/Library/Filesystems/iboysoft-ntfs.fs", "third_party": true, "claims": ["ntfs"] }
          ] }
        }
        """)

        let verdict = classify(set)
        #expect(verdict.code == .noActionableFault, "exit 0")
        #expect(verdict.aggravators.map(\.aggravatorClass) == [.driver], "DRIVER stays reported")
    }

    @Test
    func `REQ-0004 insufficient evidence is a verdict with a message and a prescription`() throws {
        let verdict = classify(try fixture("all-timeout.json"))
        let unknown = try #require(cause(.unknown, in: verdict), "UNKNOWN cause")

        #expect(!verdict.headline.isEmpty, "message")
        #expect(!unknown.cheapestTest.isEmpty, "prescription")
        #expect(!unknown.falsifiedBy.isEmpty, "falsifier")
    }
}

// MARK: - Helpers

/// Loads `Tests/Fixtures/<name>` from this file so fixtures stay outside the
/// test target without being copied into a bundle.
func fixtureData(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
}

func fixture(_ name: String) throws -> SignalSet {
    try JSONDecoder.disktriage().decode(SignalSet.self, from: fixtureData(name))
}

func decode(_ json: String) throws -> SignalSet {
    try JSONDecoder.disktriage().decode(SignalSet.self, from: Data(json.utf8))
}

func cause(_ causeClass: CauseClass, in verdict: Verdict) -> Cause? {
    verdict.causes.first { $0.causeClass == causeClass }
}
