import Foundation
import Testing
@testable import DiskTriageCore

/// The pure half of the local snapshot store (diskdoctor.md §4, §5): what a
/// snapshot is, when it may be stored, and the one rule that turns the most
/// recent PRIOR snapshot into `smart.history`.
///
/// Every record here is hand-built. A fixture is never invented: the rising
/// cases are synthetic history and are named so (docs/sdlc.md, Fixtures).
struct SnapshotHistoryTests {
    private static let key = String(repeating: "a", count: 64)
    private static let otherKey = String(repeating: "b", count: 64)

    private func record(
        _ seconds: TimeInterval,
        key: String = SnapshotHistoryTests.key,
        status: SignalStatus = .ok,
        pending: Int? = 0,
        reallocated: Int? = 5,
        uncorrectable: Int? = 0
    ) -> SnapshotRecord {
        SnapshotRecord(
            schemaVersion: SnapshotRecord.currentSchemaVersion,
            recordedAt: Date(timeIntervalSince1970: seconds),
            deviceKey: key,
            smartStatus: status,
            pending: pending,
            reallocated: reallocated,
            uncorrectable: uncorrectable
        )
    }

    private func signals(smart: SmartSignals, serial: String? = "SYNTH0000ABCD") -> SignalSet {
        SignalSet(
            schemaVersion: 1,
            collectedAt: Date(timeIntervalSince1970: 1_000),
            device: DeviceSignals(
                status: .ok,
                bsd: "disk8",
                sizeBytes: 1_073_741_824,
                model: "Synthetic Bridge Disk",
                serial: serial,
                media: "hdd",
                bus: "usb",
                bridge: nil,
                satPassthrough: nil,
                removable: false
            ),
            smart: smart,
            io: nil,
            log: nil,
            drivers: nil,
            permissions: nil,
            fs: nil,
            symptoms: nil,
            collectorNotes: nil,
            synthetic: nil
        )
    }

    // REQ-0150
    @Test("REQ0150 history comes from the most recent prior snapshot for the key")
    func REQ0150_historyComesFromTheMostRecentPriorSnapshot() throws {
        let records = [
            record(100, pending: 1, reallocated: 3),
            record(200, pending: 0, reallocated: 5),
        ]

        let prior = try #require(
            SnapshotHistory.mostRecentPrior(records, forKey: Self.key, before: Date(timeIntervalSince1970: 300))
        )
        #expect(prior.recordedAt == Date(timeIntervalSince1970: 200), "the latest prior snapshot wins")
        #expect(prior.reallocated == 5)

        let history = try #require(SnapshotHistory.history(from: prior, forKey: Self.key))
        #expect(history.recordedAt == Date(timeIntervalSince1970: 200))
        #expect(history.reallocated == 5)
        #expect(history.pending == 0)
    }

    // REQ-0151
    @Test("REQ0151 first sight has no history, and a later record is not prior")
    func REQ0151_firstSightHasNoHistory() {
        #expect(SnapshotHistory.mostRecentPrior([], forKey: Self.key, before: Date(timeIntervalSince1970: 300)) == nil)
        #expect(SnapshotHistory.history(from: nil, forKey: Self.key) == nil)

        let future = record(400, reallocated: 9)
        let before = Date(timeIntervalSince1970: 300)
        #expect(
            SnapshotHistory.mostRecentPrior([future], forKey: Self.key, before: before) == nil,
            "a record at or after the collection is not a prior snapshot"
        )
    }

    // REQ-0152
    @Test(
        "REQ0152 a prior snapshot taken under a non-ok SMART status yields no history",
        arguments: [SignalStatus.denied, .timeout, .unsupported, .error]
    )
    func REQ0152_nonOkPriorYieldsNoHistory(status: SignalStatus) {
        // The newest prior snapshot is not a measurement. An older ok record
        // does not substitute for it: that would invent a trend across a gap.
        let records = [
            record(100, reallocated: 3),
            record(200, status: status, reallocated: nil),
        ]
        let prior = SnapshotHistory.mostRecentPrior(
            records,
            forKey: Self.key,
            before: Date(timeIntervalSince1970: 300)
        )
        #expect(prior?.smartStatus == status, "the newest prior record is the one considered")
        #expect(SnapshotHistory.history(from: prior, forKey: Self.key) == nil)
    }

    // REQ-0153
    @Test("REQ0153 history never comes from a snapshot of a different device key")
    func REQ0153_historyNeverCrossesDeviceKeys() {
        let foreign = record(200, key: Self.otherKey, reallocated: 5)
        #expect(
            SnapshotHistory.mostRecentPrior([foreign], forKey: Self.key, before: Date(timeIntervalSince1970: 300)) == nil,
            "another drive's snapshot is not this drive's history"
        )
        #expect(SnapshotHistory.history(from: foreign, forKey: Self.key) == nil)
    }

    // REQ-0154
    @Test(
        "REQ0154 a snapshot is stored only when the SMART section is ok",
        arguments: [SignalStatus.denied, .timeout, .unsupported, .error]
    )
    func REQ0154_onlyOkSmartIsWorthStoring(status: SignalStatus) {
        let set = signals(smart: SmartSignals(status: status, pending: nil, reallocated: nil, uncorrectable: nil))
        #expect(
            SnapshotHistory.record(from: set, deviceKey: Self.key, recordedAt: Date(timeIntervalSince1970: 1_000)) == nil,
            "\(status) is not a measurement, so it must not become a snapshot"
        )
    }

    // REQ-0154, REQ-0155
    @Test("REQ0154_REQ0155 an ok SMART with a device key becomes a snapshot; no key never does")
    func REQ0154_onlyOkSmartIsWorthStoring_okCase() throws {
        let set = signals(smart: SmartSignals(status: .ok, pending: 0, reallocated: 8, uncorrectable: 0))

        let stored = try #require(
            SnapshotHistory.record(from: set, deviceKey: Self.key, recordedAt: Date(timeIntervalSince1970: 1_000))
        )
        #expect(stored.schemaVersion == SnapshotRecord.currentSchemaVersion)
        #expect(stored.deviceKey == Self.key)
        #expect(stored.smartStatus == .ok)
        #expect(stored.pending == 0)
        #expect(stored.reallocated == 8)
        #expect(stored.uncorrectable == 0)

        #expect(
            SnapshotHistory.record(from: set, deviceKey: nil, recordedAt: Date(timeIntervalSince1970: 1_000)) == nil,
            "a device without a serial has no key and no snapshot"
        )
        #expect(
            SnapshotHistory.record(from: set, deviceKey: "", recordedAt: Date(timeIntervalSince1970: 1_000)) == nil,
            "an empty key is no key"
        )
    }

    // REQ-0156
    @Test("REQ0156 the snapshot record never carries the raw serial")
    func REQ0156_theRecordHasNoSerialField() throws {
        let set = signals(smart: SmartSignals(status: .ok, pending: 1, reallocated: 0, uncorrectable: 0))
        let stored = try #require(
            SnapshotHistory.record(from: set, deviceKey: Self.key, recordedAt: Date(timeIntervalSince1970: 1_000))
        )

        let data = try JSONEncoder.disktriage().encode(stored)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SYNTH0000ABCD"), "the raw serial stays only in the SignalSet, never the snapshot")
        #expect(text.contains(Self.key), "the hashed key is what identifies the drive")
    }
}
