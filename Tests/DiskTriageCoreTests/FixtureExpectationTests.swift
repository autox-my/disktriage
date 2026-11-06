import Foundation
import Testing
import DiskTriageCore

/// The 12 rows of the plan's §11 table, replayed against the classifier.
/// The expectations live beside the fixtures in `expectations.json`, transcribed
/// from the table, never recomputed the way the classifier computes them.
struct FixtureExpectationTests {

    @Test
    func `REQ-0031 MiNaH is MEDIA high, DRIVER aggravator, exit 10`() throws {
        try expectFixture("minah.json")
    }

    @Test
    func `REQ-0033 a bridge that hides SMART with no other signal exits 12`() throws {
        try expectFixture("bridge-hides-smart.json")
    }

    @Test
    func `REQ-0031 a hidden SMART does not hide the kernel log: MEDIA medium, exit 10`() throws {
        try expectFixture("bridge-hides-smart-log.json")
    }

    @Test
    func `REQ-0030 clean counters and a readable filesystem exit 0`() throws {
        try expectFixture("clean.json")
    }

    @Test
    func `REQ-0039 stable reallocated 5 with no history is MEDIA low, exit 0`() throws {
        try expectFixture("stable-reallocated.json")
    }

    @Test
    func `REQ-0031 reallocated rising against a synthetic snapshot exits 10`() throws {
        try expectFixture("reallocated-rising.json")
    }

    @Test
    func `REQ-0034 filesystem-only damage exits 13`() throws {
        try expectFixture("filesystem-only.json")
    }

    @Test
    func `REQ-0032 resets plus clicking is HEAD, exit 11`() throws {
        try expectFixture("head-clicking.json")
    }

    @Test
    func `REQ-0035 all collectors timed out is UNKNOWN, exit 20`() throws {
        try expectFixture("all-timeout.json")
    }

    @Test
    func `REQ-0036 SMART denied and not root exits 21`() throws {
        try expectFixture("smart-denied-not-root.json")
    }

    @Test
    func `REQ-0049 NVMe is unsupported but imaging is still offered`() throws {
        try expectFixture("unsupported-media.json")
    }

    @Test
    func `REQ-0038 MEDIA plus BRIDGE keeps both findings and exits 10`() throws {
        try expectFixture("media-and-bridge.json")
    }
}

// MARK: - Expectation decoding

private struct ExpectedCause: Decodable {
    let causeClass: String
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case causeClass = "class"
        case confidence
    }
}

private struct ExpectedVerdict: Decodable {
    let requiredCauses: [ExpectedCause]?
    let expectNoCause: Bool?
    let requiredAggravators: [String]?
    let exitCode: Int
    let expectWarning: Bool?
    let synthetic: Bool?
    let expectImagingOffered: Bool?
    let expectUnsupported: Bool?

    enum CodingKeys: String, CodingKey {
        case requiredCauses = "required_causes"
        case expectNoCause = "expect_no_cause"
        case requiredAggravators = "required_aggravators"
        case exitCode = "exit_code"
        case expectWarning = "expect_warning"
        case synthetic
        case expectImagingOffered = "expect_imaging_offered"
        case expectUnsupported = "expect_unsupported"
    }
}

private func expectFixture(_ name: String) throws {
    let all = try JSONDecoder().decode([String: ExpectedVerdict].self, from: fixtureData("expectations.json"))
    let expected = try #require(all[name], "expectation for \(name)")
    let set = try fixture(name)
    let verdict = classify(set)

    #expect(verdict.code.rawValue == expected.exitCode, "\(name): exit code")

    for wanted in expected.requiredCauses ?? [] {
        let wantedClass = try #require(CauseClass(rawValue: wanted.causeClass), "known class")
        let found = cause(wantedClass, in: verdict)
        #expect(found != nil, "\(name): \(wanted.causeClass) cause")
        #expect(found?.confidence.rawValue == wanted.confidence,
                "\(name): \(wanted.causeClass) confidence")
    }
    if expected.expectNoCause == true {
        #expect(verdict.causes.isEmpty, "\(name): no cause")
    }
    for aggravator in expected.requiredAggravators ?? [] {
        #expect(verdict.aggravators.contains { $0.aggravatorClass.rawValue == aggravator },
                "\(name): \(aggravator) aggravator")
    }
    if expected.expectWarning == true {
        #expect(!verdict.warnings.isEmpty, "\(name): warning")
    }
    if expected.synthetic == true {
        #expect(set.synthetic == true, "\(name): labelled synthetic")
    }
    if expected.expectImagingOffered == true {
        #expect(verdict.imagingOffered, "\(name): imaging offered")
    }
    if expected.expectUnsupported == true {
        #expect(verdict.unsupportedNote != nil, "\(name): UNSUPPORTED note")
    }
}
