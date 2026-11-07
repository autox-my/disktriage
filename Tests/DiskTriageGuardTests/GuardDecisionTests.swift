import Foundation
import Testing
import DiskTriageGuard

/// The mount-approval decision, driven as a table over recorded
/// DADiskDescription samples (Tests/Fixtures/da-disk-descriptions.json).
struct GuardDecisionTests {

    // REQ-0071
    @Test("REQ0071_REQ0073 dissent only for an external physical disk, approve everything else")
    func REQ0071_REQ0073_dissentsOnlyForExternalPhysicalDisks() throws {
        for sample in try diskDescriptionSamples() {
            let description = DiskDescription(daDescription: sample.description)
            let expected = try #require(GuardVerdict(rawValue: sample.expected))
            #expect(
                guardDecision(description) == expected,
                "\(sample.name): \(sample.provenance)"
            )
        }
    }

    @Test("the recorded table covers an internal disk, an image and external disks")
    func theTableCoversEveryCaseThePlanNames() throws {
        let names = Set(try diskDescriptionSamples().map(\.name))
        #expect(names.contains("internal APFS"))
        #expect(names.contains("virtual disk image"))
        #expect(names.contains("USB NTFS volume"))
        #expect(names.contains("USB whole disk"))
    }

    @Test("an unknown internal flag approves, never vetoes")
    func anUnknownIdentityApproves() {
        let unknown = DiskDescription(protocolName: "USB", volumeKind: "ExFAT", mediaWhole: true)
        #expect(unknown.isInternal == nil)
        #expect(guardDecision(unknown) == .approve)
    }
}

struct DiskDescriptionSample {
    let name: String
    let provenance: String
    let expected: String
    let description: [String: Any]
}

func diskDescriptionSamples() throws -> [DiskDescriptionSample] {
    guard let root = try JSONSerialization.jsonObject(
        with: try Data(contentsOf: URL(fileURLWithPath: fixturePath("da-disk-descriptions.json")))
    ) as? [String: Any], let samples = root["samples"] as? [[String: Any]] else {
        throw FixtureError.unreadable
    }
    return try samples.map { sample in
        guard let name = sample["name"] as? String,
              let provenance = sample["provenance"] as? String,
              let expected = sample["expected"] as? String,
              let description = sample["description"] as? [String: Any] else {
            throw FixtureError.unreadable
        }
        return DiskDescriptionSample(
            name: name,
            provenance: provenance,
            expected: expected,
            description: description
        )
    }
}

enum FixtureError: Error {
    case unreadable
}

func fixturePath(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageGuardTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/\(name)")
        .path
}
