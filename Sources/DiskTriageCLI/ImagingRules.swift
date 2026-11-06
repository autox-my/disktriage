import Foundation
import CryptoKit
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

    public init(
        schema: String,
        device: ImageSidecarDevice,
        createdAt: String? = nil,
        command: [String]? = nil
    ) {
        self.schema = schema
        self.device = device
        self.createdAt = createdAt
        self.command = command
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case device
        case command
        case createdAt = "created_at"
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

    init(identity: DeviceIdentity) {
        bsd = identity.bsd
        model = identity.model
        serial = identity.serial?.trimmingCharacters(in: .whitespacesAndNewlines)
        sizeBytes = identity.sizeBytes
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
    /// The physical whole disk behind the destination volume (`disk0`, `disk8`).
    public let backingWholeDisk: String?
    public let backingError: String?

    public init(
        destinationExists: Bool,
        mapfileExists: Bool,
        sidecar: ImageSidecar? = nil,
        sidecarError: String? = nil,
        freeBytes: Int64? = nil,
        containerFilesystem: String? = nil,
        parentIsWritable: Bool? = nil,
        backingWholeDisk: String? = nil,
        backingError: String? = nil
    ) {
        self.destinationExists = destinationExists
        self.mapfileExists = mapfileExists
        self.sidecar = sidecar
        self.sidecarError = sidecarError
        self.freeBytes = freeBytes
        self.containerFilesystem = containerFilesystem
        self.parentIsWritable = parentIsWritable
        self.backingWholeDisk = backingWholeDisk
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
/// `nil` when either side could not be resolved (fail closed upstream).
func destinationSharesSourceDisk(backingWholeDisk: String?, sourceDisk: String?) -> Bool? {
    guard let backingWholeDisk, let sourceDisk else { return nil }
    return backingWholeDisk == sourceDisk
}

/// Free space must cover the whole device, boundary included (REQ-0079).
func freeSpaceCoversDevice(freeBytes: Int64?, deviceBytes: Int64?) -> Bool? {
    guard let freeBytes, let deviceBytes else { return nil }
    return freeBytes >= deviceBytes
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

/// The sidecar is the resume authority: size, serial hash and model must agree
/// with the device in front of us (REQ-0077). `nil` means no sidecar was read.
func sidecarMatchesDevice(
    _ sidecar: ImageSidecar?,
    model: String?,
    serialHash: String?,
    sizeBytes: Int64?
) -> Bool? {
    guard let sidecar else { return nil }
    guard let sizeBytes else { return nil }
    guard sidecar.device.sizeBytes == sizeBytes else { return false }
    guard sidecar.device.model == model else { return false }
    guard let serialHash else {
        // The current read has no serial, so only a sidecar that recorded no
        // serial can be confirmed. A recorded serial is unconfirmable, not a
        // pass.
        return sidecar.device.serialSHA256 == nil
    }
    return sidecar.device.serialSHA256 == serialHash
}

/// Every destination check, in the plan's order. Any `refuse` or `unknown`
/// blocks the plan; unknown is not a pass (diskdoctor.md §2.3).
func assessDestination(facts: DestinationFacts, source: ImageSource) -> [DestinationCheck] {
    var checks: [DestinationCheck] = []

    switch destinationSharesSourceDisk(
        backingWholeDisk: facts.backingWholeDisk,
        sourceDisk: source.bsd
    ) {
    case .some(true):
        checks.append(DestinationCheck(
            name: "not on the source disk",
            outcome: .refuse,
            detail: "destination is on \(facts.backingWholeDisk ?? source.bsd), the source disk"
        ))
    case .some(false):
        checks.append(DestinationCheck(
            name: "not on the source disk",
            outcome: .pass,
            detail: "destination is on \(facts.backingWholeDisk ?? "?")"
        ))
    case .none:
        let reason = facts.backingError ?? "the backing disk could not be resolved"
        checks.append(DestinationCheck(
            name: "not on the source disk",
            outcome: .unknown,
            detail: reason
        ))
    }

    switch freeSpaceCoversDevice(freeBytes: facts.freeBytes, deviceBytes: source.sizeBytes) {
    case .some(true):
        checks.append(DestinationCheck(
            name: "free space",
            outcome: .pass,
            detail: "\(gib(facts.freeBytes)) free ≥ \(gib(source.sizeBytes)) needed"
        ))
    case .some(false):
        checks.append(DestinationCheck(
            name: "free space",
            outcome: .refuse,
            detail: "\(gib(facts.freeBytes)) free, \(gib(source.sizeBytes)) needed"
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
    } else {
        let serialHash = source.serial.map(imageSerialHash)
        switch sidecarMatchesDevice(
            facts.sidecar,
            model: source.model,
            serialHash: serialHash,
            sizeBytes: source.sizeBytes
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
    public let argv: [String]

    public init(pass: Int, argv: [String]) {
        self.pass = pass
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
func ddrescuePasses(
    rawDevice: String,
    image: String,
    mapfile: String,
    blockSize: Int64,
    timeoutSeconds: Int = 90
) -> [DdrescuePass] {
    func argv(_ mode: String) -> [String] {
        [
            "caffeinate", "-dimsu",
            "ddrescue", mode,
            "-b", String(blockSize),
            "-O",
            "-K", "65536",
            "-T", String(timeoutSeconds),
            rawDevice, image, mapfile,
        ]
    }
    return [
        DdrescuePass(pass: 1, argv: argv("-n")),
        DdrescuePass(pass: 2, argv: argv("-r3")),
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

func imageSerialHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
