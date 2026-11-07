import Foundation

/// One local SMART snapshot, keyed by the full SHA-256 of the drive's serial
/// (diskdoctor.md §4).
///
/// A snapshot is deliberately small: the three trend counters, the UTC time it
/// was taken, the key, and the SMART section status it was taken under. The
/// raw serial is never part of it — the key is the only identifier on disk.
public struct SnapshotRecord: Codable, Equatable, Sendable {
    /// The record layout this build reads and writes. An unknown version is
    /// skipped, never guessed at (the store reports it as a note).
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let recordedAt: Date
    /// Full SHA-256 hex of the serial, never truncated and never the raw serial.
    public let deviceKey: String
    /// The status the SMART section had when this record was taken. Only `ok`
    /// is a measurement; the other statuses are kept so a bad record can be
    /// recognised and refused rather than read as zeros.
    public let smartStatus: SignalStatus
    public let pending: Int?
    public let reallocated: Int?
    public let uncorrectable: Int?

    public init(
        schemaVersion: Int = SnapshotRecord.currentSchemaVersion,
        recordedAt: Date,
        deviceKey: String,
        smartStatus: SignalStatus,
        pending: Int?,
        reallocated: Int?,
        uncorrectable: Int?
    ) {
        self.schemaVersion = schemaVersion
        self.recordedAt = recordedAt
        self.deviceKey = deviceKey
        self.smartStatus = smartStatus
        self.pending = pending
        self.reallocated = reallocated
        self.uncorrectable = uncorrectable
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordedAt = "recorded_at"
        case deviceKey = "device_key"
        case smartStatus = "smart_status"
        case pending, reallocated, uncorrectable
    }
}

/// The pure rules of the local snapshot history (diskdoctor.md §4, §5).
///
/// No filesystem and no clock: the caller supplies the records and the time.
/// "Absent is never a zero" applies here too — a snapshot taken under a
/// denied, timeout or unsupported SMART section is not a measurement and
/// yields no history, and a missing prior snapshot is `nil`, never an invented
/// baseline.
public enum SnapshotHistory {
    /// The most recent snapshot for this key strictly before `date`.
    ///
    /// The status is intentionally not filtered here: the newest prior record
    /// is the one considered, and `history(from:forKey:)` refuses it if it was
    /// not a measurement. Falling back to an older `ok` record would invent a
    /// trend across a gap.
    public static func mostRecentPrior(
        _ records: [SnapshotRecord],
        forKey key: String,
        before date: Date
    ) -> SnapshotRecord? {
        records
            .filter { $0.deviceKey == key && $0.recordedAt < date }
            .max { $0.recordedAt < $1.recordedAt }
    }

    /// The `smart.history` for the classifier, or `nil` on first sight.
    ///
    /// Conditions, all load-bearing:
    /// - a prior record exists,
    /// - it is the current schema version,
    /// - it belongs to this key (never another drive), and
    /// - its SMART section was `ok`.
    public static func history(from record: SnapshotRecord?, forKey key: String) -> SmartHistory? {
        guard let record,
              record.schemaVersion == SnapshotRecord.currentSchemaVersion,
              record.deviceKey == key,
              record.smartStatus == .ok
        else {
            return nil
        }
        return SmartHistory(
            recordedAt: record.recordedAt,
            pending: record.pending,
            reallocated: record.reallocated
        )
    }

    /// What is worth storing from a collected set.
    ///
    /// Only an `ok` SMART section is a measurement, and a device with no serial
    /// has no key, so both return `nil` — no snapshot exists for a bridge that
    /// hid SMART or for a drive the OS did not identify.
    public static func record(
        from signals: SignalSet,
        deviceKey: String?,
        recordedAt: Date
    ) -> SnapshotRecord? {
        guard let deviceKey, !deviceKey.isEmpty,
              let smart = signals.smart,
              smart.status == .ok
        else {
            return nil
        }
        return SnapshotRecord(
            schemaVersion: SnapshotRecord.currentSchemaVersion,
            recordedAt: recordedAt,
            deviceKey: deviceKey,
            smartStatus: smart.status,
            pending: smart.pending,
            reallocated: smart.reallocated,
            uncorrectable: smart.uncorrectable
        )
    }
}
