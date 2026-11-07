import Foundation
import CryptoKit
import DiskTriageCore
import DiskTriageCollectors

// The pure rules behind `disktriage image` (diskdoctor.md §6, §8). Nothing in
// this file touches a device, a filesystem or a subprocess: the OS facts are
// gathered by `SystemImageDestinationProbe` and passed in as values, so every
// refusal below is a function a test can drive.

/// A sidecar written beside an image: what device that image came from. A
/// resume is only allowed when the image, its mapfile and this record agree
/// with the device in front of us (REQ-0077).
public struct ImageSidecar: Codable, Equatable, Sendable {
    public let schema: String
    public let device: ImageSidecarDevice
    /// When this attempt started (ISO-8601). Optional so a sidecar written by
    /// the dry-run-era schema still decodes.
    public let createdAt: String?
    /// The exact argv of both passes, so the record says how the image was made.
    public let command: [String]?
    /// The byte limit of a partial image, and `nil` for a full image. It is
    /// part of the resume authority: a partial image is never continued as a
    /// full one, or with another limit (diskdoctor.md §8). Optional so a
    /// sidecar written before `--limit` existed still decodes as full.
    public let limitBytes: Int64?
    /// The pass-1 slow-zone threshold (`ddrescue -a`) this run used, `nil`
    /// when it was disabled. Informational only: the plan says changing it on
    /// resume is allowed, so it is never part of the identity check
    /// (diskdoctor.md §8, "Defer slow zones"; REQ-0183/REQ-0184).
    public let minReadRateBytesPerSecond: Int64?
    /// The allocation-aware stage state. Optional so a sidecar written before
    /// the NTFS staging existed still decodes; `--used-only` is deliberately
    /// not part of the resume identity (REQ-0207).
    public let allocation: ImageSidecarAllocation?
    /// What a `--scope-report` run learned. Optional and additive: a full run
    /// reads it for the record and re-runs stage 0 as it always does
    /// (REQ-0227).
    public let scopeReport: ImageSidecarScopeReport?

    public init(
        schema: String,
        device: ImageSidecarDevice,
        createdAt: String? = nil,
        command: [String]? = nil,
        limitBytes: Int64? = nil,
        minReadRateBytesPerSecond: Int64? = nil,
        allocation: ImageSidecarAllocation? = nil,
        scopeReport: ImageSidecarScopeReport? = nil
    ) {
        self.schema = schema
        self.device = device
        self.createdAt = createdAt
        self.command = command
        self.limitBytes = limitBytes
        self.minReadRateBytesPerSecond = minReadRateBytesPerSecond
        self.allocation = allocation
        self.scopeReport = scopeReport
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case device
        case command
        case createdAt = "created_at"
        case limitBytes = "limit_bytes"
        case minReadRateBytesPerSecond = "min_read_rate_bytes_per_second"
        case allocation
        case scopeReport = "scope_report"
    }
}

/// The stage-0 scope report the sidecar keeps. Same twelve keys as the JSON
/// `scope_report` object, with `null` (never an omitted key) for an ETA that
/// could not be computed.
public struct ImageSidecarScopeReport: Codable, Equatable, Sendable {
    public let geometrySource: String
    public let clusterBytes: Int64
    public let totalClusters: Int64
    public let usedClusters: Int64
    public let freeClusters: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let usedExtents: Int
    public let mftBytes: Int64
    public let etaLowSeconds: Double?
    public let etaHighSeconds: Double?
    public let etaBasis: String

    public init(
        geometrySource: String,
        clusterBytes: Int64,
        totalClusters: Int64,
        usedClusters: Int64,
        freeClusters: Int64,
        usedBytes: Int64,
        freeBytes: Int64,
        usedExtents: Int,
        mftBytes: Int64,
        etaLowSeconds: Double?,
        etaHighSeconds: Double?,
        etaBasis: String
    ) {
        self.geometrySource = geometrySource
        self.clusterBytes = clusterBytes
        self.totalClusters = totalClusters
        self.usedClusters = usedClusters
        self.freeClusters = freeClusters
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.usedExtents = usedExtents
        self.mftBytes = mftBytes
        self.etaLowSeconds = etaLowSeconds
        self.etaHighSeconds = etaHighSeconds
        self.etaBasis = etaBasis
    }

    enum CodingKeys: String, CodingKey {
        case geometrySource = "geometry_source"
        case clusterBytes = "cluster_bytes"
        case totalClusters = "total_clusters"
        case usedClusters = "used_clusters"
        case freeClusters = "free_clusters"
        case usedBytes = "used_bytes"
        case freeBytes = "free_bytes"
        case usedExtents = "used_extents"
        case mftBytes = "mft_bytes"
        case etaLowSeconds = "eta_low_seconds"
        case etaHighSeconds = "eta_high_seconds"
        case etaBasis = "eta_basis"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(geometrySource, forKey: .geometrySource)
        try container.encode(clusterBytes, forKey: .clusterBytes)
        try container.encode(totalClusters, forKey: .totalClusters)
        try container.encode(usedClusters, forKey: .usedClusters)
        try container.encode(freeClusters, forKey: .freeClusters)
        try container.encode(usedBytes, forKey: .usedBytes)
        try container.encode(freeBytes, forKey: .freeBytes)
        try container.encode(usedExtents, forKey: .usedExtents)
        try container.encode(mftBytes, forKey: .mftBytes)
        try container.encode(etaBasis, forKey: .etaBasis)
        if let etaLowSeconds {
            try container.encode(etaLowSeconds, forKey: .etaLowSeconds)
        } else {
            try container.encodeNil(forKey: .etaLowSeconds)
        }
        if let etaHighSeconds {
            try container.encode(etaHighSeconds, forKey: .etaHighSeconds)
        } else {
            try container.encodeNil(forKey: .etaHighSeconds)
        }
    }
}

/// The stage state the sidecar records so an interrupted run resumes at the
/// right stage. Strings, not enums: an unknown value from a later version is
/// read as "not started", never as a crash.
public struct ImageSidecarAllocation: Codable, Equatable, Sendable {
    public let usedOnly: Bool
    /// `allocation-aware` or `whole-device` (the stage-0 fallback).
    public let mode: String
    /// `not-started | done | failed`.
    public let stage0: String
    public let stage0Reason: String?
    /// `primary | backup`, `nil` when stage 0 did not select a boot sector.
    public let geometrySource: String?
    /// `not-started | pass1 | pass2 | done | skipped | plain`.
    public let stage1: String
    /// `not-started | pass1 | pass2 | done | skipped | plain`.
    public let stage2: String

    public init(
        usedOnly: Bool,
        mode: String,
        stage0: String,
        stage0Reason: String? = nil,
        geometrySource: String? = nil,
        stage1: String,
        stage2: String
    ) {
        self.usedOnly = usedOnly
        self.mode = mode
        self.stage0 = stage0
        self.stage0Reason = stage0Reason
        self.geometrySource = geometrySource
        self.stage1 = stage1
        self.stage2 = stage2
    }

    enum CodingKeys: String, CodingKey {
        case usedOnly = "used_only"
        case mode
        case stage0
        case stage0Reason = "stage0_reason"
        case geometrySource = "geometry_source"
        case stage1
        case stage2
    }
}

public struct ImageSidecarDevice: Codable, Equatable, Sendable {
    public let model: String?
    public let serialSHA256: String?
    public let sizeBytes: Int64

    public init(model: String?, serialSHA256: String?, sizeBytes: Int64) {
        self.model = model
        self.serialSHA256 = serialSHA256
        self.sizeBytes = sizeBytes
    }

    enum CodingKeys: String, CodingKey {
        case model
        case serialSHA256 = "serial_sha256"
        case sizeBytes = "size_bytes"
    }
}

/// The source device as the image command needs it. `bsd` alone is never the
/// identity (diskdoctor.md §6); model, serial and size are shown and confirmed.
struct ImageSource: Equatable, Sendable {
    let bsd: String
    let model: String?
    let serial: String?
    let sizeBytes: Int64?
    let blockSize: Int64?
    let bus: String?
    let media: String?

    init(identity: DeviceIdentity, sizeBytesOverride: Int64? = nil) {
        bsd = identity.bsd
        model = identity.model
        serial = identity.serial?.trimmingCharacters(in: .whitespacesAndNewlines)
        sizeBytes = sizeBytesOverride ?? identity.sizeBytes
        blockSize = identity.blockSize
        bus = identity.bus
        media = identity.media
    }

    init(
        bsd: String,
        model: String? = nil,
        serial: String? = nil,
        sizeBytes: Int64? = nil,
        blockSize: Int64? = nil,
        bus: String? = nil,
        media: String? = nil
    ) {
        self.bsd = bsd
        self.model = model
        self.serial = serial?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sizeBytes = sizeBytes
        self.blockSize = blockSize
        self.bus = bus
        self.media = media
    }

    /// The four characters the user is asked to type (REQ-0051). `nil` when
    /// the bridge hides the serial, which is common over USB (P0 phase B).
    var serialLast4: String? {
        guard let serial, serial.count >= 4 else { return nil }
        return String(serial.suffix(4))
    }

    /// The integer GiB used when the serial is unreadable. Truncated, so a
    /// 233.76 GiB device asks for 233. The exact value is printed.
    var sizeGiB: Int64? {
        guard let sizeBytes else { return nil }
        return sizeBytes / 1_073_741_824
    }
}

/// The read-only facts the destination checks need. `nil` means the probe
/// could not establish the fact; that is never treated as a pass.
public struct DestinationFacts: Equatable, Sendable {
    public let destinationExists: Bool
    public let mapfileExists: Bool
    public let sidecar: ImageSidecar?
    public let sidecarError: String?
    public let freeBytes: Int64?
    public let containerFilesystem: String?
    public let parentIsWritable: Bool?
    /// Every physical whole disk behind the destination volume (`disk0`,
    /// `disk8`). An APFS container can have more than one store, so this is a
    /// set: any member equal to the source disk is a refusal.
    public let backingWholeDisks: [String]
    public let backingError: String?

    /// The single backing disk for display, when the probe found one.
    public var backingWholeDisk: String? { backingWholeDisks.first }

    public init(
        destinationExists: Bool,
        mapfileExists: Bool,
        sidecar: ImageSidecar? = nil,
        sidecarError: String? = nil,
        freeBytes: Int64? = nil,
        containerFilesystem: String? = nil,
        parentIsWritable: Bool? = nil,
        backingWholeDisk: String? = nil,
        backingError: String? = nil,
        backingWholeDisks: [String]? = nil
    ) {
        self.destinationExists = destinationExists
        self.mapfileExists = mapfileExists
        self.sidecar = sidecar
        self.sidecarError = sidecarError
        self.freeBytes = freeBytes
        self.containerFilesystem = containerFilesystem
        self.parentIsWritable = parentIsWritable
        self.backingWholeDisks = backingWholeDisks ?? backingWholeDisk.map { [$0] } ?? []
        self.backingError = backingError
    }
}

/// What a destination probe does. The shipped implementation reads `statfs`
/// and `diskutil`; tests pass a recording fake, so no test touches a disk.
public protocol ImageDestinationProbing: Sendable {
    func probe(destination: String, mapfile: String) -> DestinationFacts
}

public enum CheckOutcome: String, Equatable, Sendable {
    case pass
    case refuse
    case unknown
}

public struct DestinationCheck: Equatable, Sendable {
    public let name: String
    public let outcome: CheckOutcome
    public let detail: String

    public init(name: String, outcome: CheckOutcome, detail: String) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
    }
}

// MARK: - Individual destination rules

/// True when the destination volume's backing whole disk is the source disk.
/// `nil` when either side could not be resolved (fail closed upstream). A
/// multi-store APFS container is a set: any store equal to the source is a
/// refusal.
func destinationSharesSourceDisk(backingWholeDisks: [String], sourceDisk: String?) -> Bool? {
    guard let sourceDisk, !backingWholeDisks.isEmpty else { return nil }
    return backingWholeDisks.contains(sourceDisk)
}

/// The single-disk form, kept for the table-driven rule tests.
func destinationSharesSourceDisk(backingWholeDisk: String?, sourceDisk: String?) -> Bool? {
    guard let backingWholeDisk else { return nil }
    return destinationSharesSourceDisk(backingWholeDisks: [backingWholeDisk], sourceDisk: sourceDisk)
}

/// Free space must cover the image being written, boundary included
/// (REQ-0079). For a partial image the number that must fit is the limit
/// (REQ-0103); the caller decides which size to pass.
func freeSpaceCoversDevice(freeBytes: Int64?, deviceBytes: Int64?) -> Bool? {
    guard let freeBytes, let deviceBytes else { return nil }
    return freeBytes >= deviceBytes
}

// MARK: - The slow-zone threshold

/// `--min-read-rate <MB/s>` is decimal megabytes (diskdoctor.md §8): 1 MB/s is
/// 1,000,000 bytes/s because `ddrescue -a` takes bytes/s. Zero disables the
/// flag, so it returns `nil` (REQ-0179).
func minReadRateBytesPerSecond(megabytesPerSecond: Int64) -> Int64? {
    guard megabytesPerSecond > 0 else { return nil }
    let (bytes, overflow) = megabytesPerSecond.multipliedReportingOverflow(by: 1_000_000)
    return overflow ? nil : bytes
}

/// The plan's default: 10 MB/s on rotational (HDD) or unknown media, and 0
/// (the flag is omitted) for SSD, flash, SD, NVMe or any media the plan calls
/// unsupported (REQ-0180). Unknown media is never assumed to be solid-state.
func defaultMinReadRateMBps(media: String?, bus: String?) -> Int64 {
    if MediaSupport.unsupportedLabel(media: media, bus: bus) != nil {
        return 0
    }
    switch media?.lowercased() {
    case "hdd", "unknown", nil:
        return 10
    default:
        return 0
    }
}

// MARK: - The `--limit` seam

/// GiB is 2^30 bytes (diskdoctor.md §8). `nil` is not a positive limit, and an
/// unrepresentable one is refused rather than wrapped.
func limitBytesForGiB(_ giB: Int64) -> Int64? {
    guard giB > 0 else { return nil }
    let (bytes, overflow) = giB.multipliedReportingOverflow(by: 1_073_741_824)
    return overflow ? nil : bytes
}

/// The number of bytes the image will contain: the limit when it is strictly
/// below the device, otherwise the whole device. `nil` when the device size is
/// unknown, because then "partial" cannot be established (REQ-0101).
func effectiveImageBytes(deviceBytes: Int64?, limitBytes: Int64?) -> Int64? {
    guard let deviceBytes else { return nil }
    guard let limitBytes else { return deviceBytes }
    return min(deviceBytes, limitBytes)
}

/// True only when a limit was asked for and is strictly below a known device
/// size. A limit at or above the device is the full device, not a partial
/// image (REQ-0101).
func imageIsPartial(deviceBytes: Int64?, limitBytes: Int64?) -> Bool {
    guard let deviceBytes, let limitBytes else { return false }
    return limitBytes > 0 && limitBytes < deviceBytes
}

/// The limit a sidecar records: the effective partial limit, or `nil` for a
/// full image (including a limit at or above the device).
func recordedLimitBytes(deviceBytes: Int64?, limitBytes: Int64?) -> Int64? {
    imageIsPartial(deviceBytes: deviceBytes, limitBytes: limitBytes) ? limitBytes : nil
}

/// MS-DOS/FAT32 has a 4 GiB single-file limit; exFAT and the native
/// filesystems do not (REQ-0079).
func filesystemAllowsLargeFiles(_ filesystem: String?) -> Bool? {
    guard let filesystem = filesystem?.lowercased() else { return nil }
    return !["msdos", "fat", "fat32"].contains(filesystem)
}

func destinationIsWritable(_ writable: Bool?) -> Bool? {
    writable
}

/// An existing image is resumed only with its mapfile; otherwise a write would
/// silently destroy the earlier attempt (REQ-0078).
func existingImageNeedsMapfile(imageExists: Bool, mapfileExists: Bool) -> Bool {
    imageExists && !mapfileExists
}

/// The sidecar is the resume authority: size, serial hash, model and the
/// partial limit must agree with the device in front of us (REQ-0077,
/// REQ-0105). `limitBytes` is the effective partial limit, `nil` for a full
/// image. `nil` as the answer means no sidecar was read.
func sidecarMatchesDevice(
    _ sidecar: ImageSidecar?,
    model: String?,
    serialHash: String?,
    sizeBytes: Int64?,
    limitBytes: Int64? = nil
) -> Bool? {
    guard let sidecar else { return nil }
    guard let sizeBytes else { return nil }
    guard sidecar.device.sizeBytes == sizeBytes else { return false }
    guard sidecar.limitBytes == limitBytes else { return false }
    guard sidecar.device.model == model else { return false }
    guard let serialHash else {
        // The current read has no serial, so only a sidecar that recorded no
        // serial can be confirmed. A recorded serial is unconfirmable, not a
        // pass.
        return sidecar.device.serialSHA256 == nil
    }
    return sidecar.device.serialSHA256 == serialHash
}

/// True when the sidecar records a different limit than this run would use,
/// including full versus partial. It is split out from `sidecarMatchesDevice`
/// so the refusal can name what the sidecar records and what was requested
/// (REQ-0105).
func sidecarLimitMismatch(_ sidecar: ImageSidecar?, limitBytes: Int64?) -> Bool {
    guard let sidecar else { return false }
    return sidecar.limitBytes != limitBytes
}

/// Every destination check, in the plan's order. Any `refuse` or `unknown`
/// blocks the plan; unknown is not a pass (diskdoctor.md §2.3).
func assessDestination(
    facts: DestinationFacts,
    source: ImageSource,
    limitBytes: Int64? = nil
) -> [DestinationCheck] {
    var checks: [DestinationCheck] = []
    let imageBytes = effectiveImageBytes(deviceBytes: source.sizeBytes, limitBytes: limitBytes)
    let isPartial = imageIsPartial(deviceBytes: source.sizeBytes, limitBytes: limitBytes)
    let recordedLimit = recordedLimitBytes(deviceBytes: source.sizeBytes, limitBytes: limitBytes)

    switch destinationSharesSourceDisk(
        backingWholeDisks: facts.backingWholeDisks,
        sourceDisk: source.bsd
    ) {
    case .some(true):
        checks.append(DestinationCheck(
            name: "not on the source disk",
            outcome: .refuse,
            detail: "destination is on \(facts.backingWholeDisks.joined(separator: ", ")), the source disk"
        ))
    case .some(false):
        checks.append(DestinationCheck(
            name: "not on the source disk",
            outcome: .pass,
            detail: "destination is on \(facts.backingWholeDisks.joined(separator: ", "))"
        ))
    case .none:
        let reason = facts.backingError ?? "the backing disk could not be resolved"
        checks.append(DestinationCheck(
            name: "not on the source disk",
            outcome: .unknown,
            detail: reason
        ))
    }

    // A partial image only needs room for the limit (REQ-0103); the detail
    // still names the whole device, so neither number is hidden.
    let partialNote = isPartial
        ? " (partial limit of the \(gib(source.sizeBytes)) device)"
        : ""
    switch freeSpaceCoversDevice(freeBytes: facts.freeBytes, deviceBytes: imageBytes) {
    case .some(true):
        checks.append(DestinationCheck(
            name: "free space",
            outcome: .pass,
            detail: "\(gib(facts.freeBytes)) free ≥ \(gib(imageBytes)) needed\(partialNote)"
        ))
    case .some(false):
        checks.append(DestinationCheck(
            name: "free space",
            outcome: .refuse,
            detail: "\(gib(facts.freeBytes)) free, \(gib(imageBytes)) needed\(partialNote)"
        ))
    case .none:
        checks.append(DestinationCheck(
            name: "free space",
            outcome: .unknown,
            detail: "free space or source size is unknown"
        ))
    }

    switch filesystemAllowsLargeFiles(facts.containerFilesystem) {
    case .some(true):
        checks.append(DestinationCheck(
            name: "file-size limit",
            outcome: .pass,
            detail: "\(facts.containerFilesystem ?? "?") has no 4 GiB file-size limit"
        ))
    case .some(false):
        checks.append(DestinationCheck(
            name: "file-size limit",
            outcome: .refuse,
            detail: "\(facts.containerFilesystem ?? "?") stops at 4 GiB per file"
        ))
    case .none:
        checks.append(DestinationCheck(
            name: "file-size limit",
            outcome: .unknown,
            detail: "the destination filesystem could not be determined"
        ))
    }

    switch destinationIsWritable(facts.parentIsWritable) {
    case .some(true):
        checks.append(DestinationCheck(
            name: "writable",
            outcome: .pass,
            detail: "the destination directory is writable"
        ))
    case .some(false):
        checks.append(DestinationCheck(
            name: "writable",
            outcome: .refuse,
            detail: "the destination directory is not writable"
        ))
    case .none:
        checks.append(DestinationCheck(
            name: "writable",
            outcome: .unknown,
            detail: "writability could not be determined"
        ))
    }

    if existingImageNeedsMapfile(imageExists: facts.destinationExists, mapfileExists: facts.mapfileExists) {
        checks.append(DestinationCheck(
            name: "resume metadata",
            outcome: .refuse,
            detail: "the image exists without a mapfile; refusing to overwrite it"
        ))
    } else if !facts.destinationExists {
        checks.append(DestinationCheck(
            name: "resume metadata",
            outcome: .pass,
            detail: "no existing image"
        ))
    } else if let error = facts.sidecarError {
        checks.append(DestinationCheck(
            name: "resume metadata",
            outcome: .refuse,
            detail: "cannot read the sidecar: \(error)"
        ))
    } else if sidecarLimitMismatch(facts.sidecar, limitBytes: recordedLimit) {
        let recorded = facts.sidecar?.limitBytes.map { "a \(gib($0)) partial limit" }
            ?? "a full image"
        let requested = recordedLimit.map { "a \(gib($0)) partial limit" }
            ?? "a full image"
        checks.append(DestinationCheck(
            name: "resume metadata",
            outcome: .refuse,
            detail: "the sidecar records \(recorded); this run is \(requested); "
                + "refusing to mix a partial image with a full one or to change the limit"
        ))
    } else {
        let serialHash = source.serial.map(imageSerialHash)
        switch sidecarMatchesDevice(
            facts.sidecar,
            model: source.model,
            serialHash: serialHash,
            sizeBytes: source.sizeBytes,
            limitBytes: recordedLimit
        ) {
        case .some(true):
            checks.append(DestinationCheck(
                name: "resume metadata",
                outcome: .pass,
                detail: "image, mapfile and sidecar match \(source.model ?? source.bsd)"
            ))
        case .some(false):
            checks.append(DestinationCheck(
                name: "resume metadata",
                outcome: .refuse,
                detail: "the sidecar names a different device"
            ))
        case .none:
            checks.append(DestinationCheck(
                name: "resume metadata",
                outcome: .refuse,
                detail: "no sidecar; cannot verify that this image belongs to the device"
            ))
        }
    }

    return checks
}

// MARK: - Pass-2 stop rule

public struct Pass2Sample: Equatable, Sendable {
    public let time: Date
    public let rescuedBytes: Int64

    public init(time: Date, rescuedBytes: Int64) {
        self.time = time
        self.rescuedBytes = rescuedBytes
    }
}

public struct Pass2Stop: Equatable, Sendable {
    public let remainingBytes: Int64
    public let marginalYieldBytes: Int64
    public let projectedRemainingSeconds: Double
    public let elapsedSeconds: Double

    public init(
        remainingBytes: Int64,
        marginalYieldBytes: Int64,
        projectedRemainingSeconds: Double,
        elapsedSeconds: Double
    ) {
        self.remainingBytes = remainingBytes
        self.marginalYieldBytes = marginalYieldBytes
        self.projectedRemainingSeconds = projectedRemainingSeconds
        self.elapsedSeconds = elapsedSeconds
    }
}

public enum Pass2Decision: Equatable, Sendable {
    case continueImaging
    case stop(Pass2Stop)

    public var stop: Pass2Stop? {
        if case let .stop(value) = self { return value }
        return nil
    }
}

/// diskdoctor.md §8: stop when the marginal yield over the trailing ten
/// minutes is < 0.01% of the device size **and** the projected remaining time
/// is greater than twice the time elapsed. The reference trigger is the
/// measured ~200 B/s case (REQ-0084).
///
/// The trailing-window baseline is the last sample at or before `now - 600`;
/// without ten minutes of history the rule cannot fire, because it has not
/// observed a ten-minute window.
func pass2StopDecision(history: [Pass2Sample], deviceSize: Int64, now: Date) -> Pass2Decision {
    let samples = history.filter { $0.time <= now }.sorted { $0.time < $1.time }
    guard deviceSize > 0,
          samples.count >= 2,
          let first = samples.first,
          let latest = samples.last
    else {
        return .continueImaging
    }

    let windowStart = now.addingTimeInterval(-600)
    guard now.timeIntervalSince(first.time) >= 600,
          let baseline = samples.last(where: { $0.time <= windowStart })
    else {
        return .continueImaging
    }

    let yield = max(0, latest.rescuedBytes - baseline.rescuedBytes)
    let windowSeconds = now.timeIntervalSince(baseline.time)
    guard windowSeconds > 0 else { return .continueImaging }

    let threshold = Double(deviceSize) * 0.0001
    let remaining = max(0, deviceSize - latest.rescuedBytes)
    let rate = Double(yield) / windowSeconds
    let projected = rate > 0 ? Double(remaining) / rate : Double.infinity
    let elapsed = now.timeIntervalSince(first.time)

    if Double(yield) < threshold, projected > 2 * elapsed {
        return .stop(Pass2Stop(
            remainingBytes: remaining,
            marginalYieldBytes: yield,
            projectedRemainingSeconds: projected,
            elapsedSeconds: elapsed
        ))
    }
    return .continueImaging
}

// MARK: - ETA

public struct ETARange: Equatable, Sendable {
    public let lowSeconds: Double
    public let highSeconds: Double
    public let lowBytesPerSecond: Double
    public let highBytesPerSecond: Double
    public let basis: String

    public init(
        lowSeconds: Double,
        highSeconds: Double,
        lowBytesPerSecond: Double,
        highBytesPerSecond: Double,
        basis: String
    ) {
        self.lowSeconds = lowSeconds
        self.highSeconds = highSeconds
        self.lowBytesPerSecond = lowBytesPerSecond
        self.highBytesPerSecond = highBytesPerSecond
        self.basis = basis
    }
}

public struct BusSpeedRange: Equatable, Sendable {
    public let lowBytesPerSecond: Double
    public let highBytesPerSecond: Double
    public let basis: String

    public init(lowBytesPerSecond: Double, highBytesPerSecond: Double, basis: String) {
        self.lowBytesPerSecond = lowBytesPerSecond
        self.highBytesPerSecond = highBytesPerSecond
        self.basis = basis
    }
}

/// An assumed bus speed, labelled as assumed. The image command prints it as a
/// range, never as a promise (REQ-0087).
func assumedBusSpeed(bus: String?) -> BusSpeedRange {
    let mb = 1_000_000.0
    switch bus?.lowercased() {
    case "usb":
        return BusSpeedRange(
            lowBytesPerSecond: 25 * mb,
            highBytesPerSecond: 30 * mb,
            basis: "assumed USB 25–30 MB/s (not measured)"
        )
    case "sata", "sata-iii":
        return BusSpeedRange(
            lowBytesPerSecond: 100 * mb,
            highBytesPerSecond: 150 * mb,
            basis: "assumed SATA 100–150 MB/s (not measured)"
        )
    case "thunderbolt":
        return BusSpeedRange(
            lowBytesPerSecond: 80 * mb,
            highBytesPerSecond: 100 * mb,
            basis: "assumed Thunderbolt 80–100 MB/s (not measured)"
        )
    case "nvme", "pcie":
        return BusSpeedRange(
            lowBytesPerSecond: 500 * mb,
            highBytesPerSecond: 1_000 * mb,
            basis: "assumed NVMe/PCIe 500–1,000 MB/s (not measured)"
        )
    default:
        return BusSpeedRange(
            lowBytesPerSecond: 25 * mb,
            highBytesPerSecond: 30 * mb,
            basis: "assumed 25–30 MB/s (bus unknown, not measured)"
        )
    }
}

func etaRange(
    deviceBytes: Int64,
    lowBytesPerSecond: Double,
    highBytesPerSecond: Double,
    basis: String
) -> ETARange? {
    guard deviceBytes > 0, lowBytesPerSecond > 0, highBytesPerSecond > 0 else { return nil }
    return ETARange(
        lowSeconds: Double(deviceBytes) / highBytesPerSecond,
        highSeconds: Double(deviceBytes) / lowBytesPerSecond,
        lowBytesPerSecond: lowBytesPerSecond,
        highBytesPerSecond: highBytesPerSecond,
        basis: basis
    )
}

// MARK: - ddrescue command

public struct DdrescuePass: Equatable, Sendable {
    public let pass: Int
    /// 0 for the plain fallback (or a whole-device pass), 0 for stage 0's
    /// metadata reads, 1 or 2 for the allocation-aware stages.
    public let stage: Int
    public let argv: [String]

    public init(pass: Int, argv: [String], stage: Int = 0) {
        self.pass = pass
        self.stage = stage
        self.argv = argv
    }

    public var line: String {
        argv.joined(separator: " ")
    }
}

/// The raw character node. `/dev/diskN` is the buffered node and `-d`
/// (direct I/O) fails on macOS 27.2 (P0 row 9); neither is ever emitted.
func rawDeviceNode(for bsd: String) -> String {
    "/dev/r" + bsd
}

/// Pass 1 (`-n`, fast sweep) then pass 2 (`-r3`, scrape), with the measured
/// wrapper defaults: `-b` = device block size, `-O` reopen, `-K 65536` skip
/// size, `-T` timeout, and `caffeinate` to stop the Mac sleeping (REQ-0083).
/// A partial image adds `-s <bytes>` to **both** passes, because pass 2 must
/// still be bounded by the same limit (REQ-0102).
///
/// `minReadRateBytesPerSecond` is `ddrescue -a`: pass 1 skips a zone reading
/// slower than the threshold and leaves it for pass 2, which deliberately has
/// no `-a` because coming back to those zones is the point (REQ-0179).
func ddrescuePasses(
    rawDevice: String,
    image: String,
    mapfile: String,
    blockSize: Int64,
    timeoutSeconds: Int = 90,
    limitBytes: Int64? = nil,
    minReadRateBytesPerSecond: Int64? = nil
) -> [DdrescuePass] {
    func argv(_ mode: String, minReadRate: Int64?) -> [String] {
        var arguments = [
            "caffeinate", "-dimsu",
            "ddrescue", mode,
            "-b", String(blockSize),
            "-O",
            "-K", "65536",
            "-T", String(timeoutSeconds),
        ]
        if let minReadRate {
            arguments += ["-a", String(minReadRate)]
        }
        if let limitBytes {
            arguments += ["-s", String(limitBytes)]
        }
        arguments += [rawDevice, image, mapfile]
        return arguments
    }
    return [
        DdrescuePass(pass: 1, argv: argv("-n", minReadRate: minReadRateBytesPerSecond)),
        DdrescuePass(pass: 2, argv: argv("-r3", minReadRate: nil)),
    ]
}

/// The stage-0 metadata read. No `-n`/`-r3`: these are small, targeted reads,
/// and `-m` is the only thing that decides what is copied. `-a` is not used
/// either: a metadata read is not a fast sweep (REQ-0205).
func ddrescueStage0Command(
    rawDevice: String,
    image: String,
    mapfile: String,
    domainMapfile: String,
    blockSize: Int64,
    timeoutSeconds: Int = 90,
    limitBytes: Int64? = nil
) -> [String] {
    var arguments = [
        "caffeinate", "-dimsu",
        "ddrescue",
        "-b", String(blockSize),
        "-O",
        "-K", "65536",
        "-T", String(timeoutSeconds),
        "-m", domainMapfile,
    ]
    if let limitBytes {
        arguments += ["-s", String(limitBytes)]
    }
    arguments += [rawDevice, image, mapfile]
    return arguments
}

/// One allocation-aware stage's two passes. Pass 1 carries `-n` and, when it is
/// not disabled, `-a`; pass 2 carries `-r3` and never `-a`, because coming back
/// to the deferred zones is its purpose (REQ-0205). `-m` restricts both to the
/// stage's domain mapfile.
func ddrescueStagePasses(
    rawDevice: String,
    image: String,
    mapfile: String,
    domainMapfile: String,
    blockSize: Int64,
    stage: Int,
    timeoutSeconds: Int = 90,
    limitBytes: Int64? = nil,
    minReadRateBytesPerSecond: Int64? = nil
) -> [DdrescuePass] {
    func argv(_ mode: String, minReadRate: Int64?) -> [String] {
        var arguments = [
            "caffeinate", "-dimsu",
            "ddrescue", mode,
            "-b", String(blockSize),
            "-O",
            "-K", "65536",
            "-T", String(timeoutSeconds),
        ]
        if let minReadRate {
            arguments += ["-a", String(minReadRate)]
        }
        arguments += ["-m", domainMapfile]
        if let limitBytes {
            arguments += ["-s", String(limitBytes)]
        }
        arguments += [rawDevice, image, mapfile]
        return arguments
    }
    return [
        DdrescuePass(
            pass: 1,
            argv: argv("-n", minReadRate: minReadRateBytesPerSecond),
            stage: stage
        ),
        DdrescuePass(pass: 2, argv: argv("-r3", minReadRate: nil), stage: stage),
    ]
}

// MARK: - Backing-disk resolution

/// `"/dev/disk3s5"` → `"disk3"`, `"/dev/rdisk8"` → `"disk8"`. The whole disk is
/// the identity a destination must differ from; a slice name is not.
func wholeDiskName(fromDevicePath path: String) -> String? {
    var name = (path as NSString).lastPathComponent
    if name.hasPrefix("r") {
        name.removeFirst()
    }
    guard name.hasPrefix("disk") else { return nil }
    let digits = name.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty else { return nil }
    return "disk" + digits
}

/// The physical whole disk behind a mounted volume, from one
/// `diskutil info -plist <whole disk>` recording.
///
/// A synthesized APFS container reports `VirtualOrPhysical = Virtual`; its
/// `APFSPhysicalStores` name the physical slice (`disk0s2`). When that key is
/// absent, `DeviceNode` is the fallback (`/dev/disk0` in the recorded
/// fixture). A physical whole disk is its own backing.
func physicalBackingDisk(fromInfoPList data: Data, current: String) -> String? {
    guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let plist = parsed as? [String: Any]
    else {
        return nil
    }

    let isVirtual = (plist["VirtualOrPhysical"] as? String)?.lowercased() == "virtual"
    if isVirtual {
        if let stores = plist["APFSPhysicalStores"] as? [[String: Any]],
           let store = stores.first?["APFSPhysicalStore"] as? String,
           let whole = wholeDiskName(fromDevicePath: store),
           whole != current {
            return whole
        }
        if let node = plist["DeviceNode"] as? String,
           let whole = wholeDiskName(fromDevicePath: node),
           whole != current {
            return whole
        }
        return nil
    }

    if let node = plist["DeviceNode"] as? String, let whole = wholeDiskName(fromDevicePath: node) {
        return whole
    }
    return wholeDiskName(fromDevicePath: current)
}

// MARK: - Formatting helpers


func gib(_ bytes: Int64?) -> String {
    guard let bytes else { return "unknown" }
    return String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
}

/// The extent a partial image covers, for the "partial image complete (first
/// N GiB)" wording (REQ-0106). Whole GiB reads as "8 GiB"; anything smaller
/// (the test seam) reads in bytes rather than a misleading "0.0 GiB".
func partialExtentLabel(_ bytes: Int64) -> String {
    if bytes > 0, bytes % 1_073_741_824 == 0 {
        return "\(bytes / 1_073_741_824) GiB"
    }
    return "\(bytes) bytes"
}

func imageSerialHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
