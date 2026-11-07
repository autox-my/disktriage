import Foundation

// MARK: - Extent and cluster math

/// A byte extent from a mapfile, kept in the mapfile's own (image) coordinates.
public struct ByteRange: Equatable, Sendable {
    public let position: Int64
    public let size: Int64

    public init(position: Int64, size: Int64) {
        self.position = position
        self.size = size
    }

    public var end: Int64 { position + size }
}

/// An inclusive, volume-relative cluster interval. The ntfs-3g tools name
/// clusters relative to the volume start, so every image byte offset must lose
/// the partition offset before it becomes a cluster.
public struct ClusterRange: Equatable, Sendable, Comparable {
    public let first: Int64
    public let last: Int64

    public init?(first: Int64, last: Int64) {
        guard first >= 0, last >= first else { return nil }
        self.first = first
        self.last = last
    }

    public var count: Int64 { last - first + 1 }

    public func intersects(_ other: ClusterRange) -> Bool {
        first <= other.last && other.first <= last
    }

    /// Clips to `[0, clusterCount)`. `nil` when the range starts at or after
    /// the volume end, or the volume is empty.
    public func clamped(toClusterCount clusterCount: Int64) -> ClusterRange? {
        guard clusterCount > 0 else { return nil }
        let first = max(self.first, 0)
        let last = min(self.last, clusterCount - 1)
        return ClusterRange(first: first, last: last)
    }

    public static func < (lhs: ClusterRange, rhs: ClusterRange) -> Bool {
        lhs.first == rhs.first ? lhs.last < rhs.last : lhs.first < rhs.first
    }
}

/// The mapfile → cluster conversion from diskdoctor.md §8. Rounding is
/// **outward**: a bad extent that touches part of a cluster makes the whole
/// cluster bad, because the copy reads whole clusters.
public enum CopyExtentMath {
    public static func clusterRange(
        for extent: ByteRange,
        partitionOffset: Int64,
        clusterSize: Int,
        volumeClusters: Int64? = nil
    ) -> ClusterRange? {
        guard extent.size > 0, clusterSize > 0 else { return nil }
        let volumeStart = extent.position - partitionOffset
        let volumeEnd = extent.end - partitionOffset
        // Entirely before the volume: not a cluster of this volume.
        guard volumeEnd > 0 else { return nil }

        let first = floorDivide(volumeStart, Int64(clusterSize))
        let last = floorDivide(volumeEnd - 1, Int64(clusterSize))
        guard let range = ClusterRange(first: max(0, first), last: last) else { return nil }
        guard let volumeClusters else { return range }
        return range.clamped(toClusterCount: volumeClusters)
    }

    /// `Int64` division truncates toward zero; the extent math needs the floor
    /// for negative offsets (a mapfile extent that starts before the volume).
    static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        guard divisor > 0 else { return 0 }
        if value >= 0 { return value / divisor }
        return -((-value + divisor - 1) / divisor)
    }
}

// MARK: - ntfscluster -c <range> -v

/// One VCN/LCN run as `ntfscluster -c <range> -v` prints it, with the inode and
/// path from the line that follows the run.
public struct NTFSVolumeRun: Equatable, Sendable {
    public let inode: Int
    public let path: String
    public let attribute: String
    public let firstLCN: Int64
    public let lastLCN: Int64

    public init(
        inode: Int,
        path: String,
        attribute: String,
        firstLCN: Int64,
        lastLCN: Int64
    ) {
        self.inode = inode
        self.path = path
        self.attribute = attribute
        self.firstLCN = firstLCN
        self.lastLCN = lastLCN
    }

    public var range: ClusterRange? { ClusterRange(first: firstLCN, last: lastLCN) }
}

public struct NTFSClusterMap: Equatable, Sendable {
    public let runs: [NTFSVolumeRun]
    public let inodeCount: Int
    /// The 200,000-run work cap was reached: the map is incomplete and no
    /// per-file claim may be made from it.
    public let truncated: Bool

    public init(runs: [NTFSVolumeRun], inodeCount: Int, truncated: Bool) {
        self.runs = runs
        self.inodeCount = inodeCount
        self.truncated = truncated
    }
}

/// Parses the real `ntfscluster -c 0-(N-1) -v` output recorded in
/// `Tests/Fixtures/ntfscluster-*.txt`. Pure: the caller runs the tool.
///
/// ```
/// Inode: 89
///     [0x80]
///         VCN     LCN     Length
///         0       2153-2153 (1)
/// Inode 89 /media/big.bin/$DATA
/// ```
public enum NTFSClusterOutputParser {
    /// The plan's guard: 200,000 runs ≈ 43 MB by the spike's measured 215 B/run.
    public static let defaultMaxRuns = 200_000

    public static func parse(_ text: String, maxRuns: Int = defaultMaxRuns) -> NTFSClusterMap {
        var runs: [NTFSVolumeRun] = []
        var currentAttribute: String?
        var pending: [(first: Int64, last: Int64)] = []
        var truncated = false

        let runLine = try! NSRegularExpression(
            pattern: #"^\s*(\d+)\s+(-?\d+)-(-?\d+)\s+\((\d+)\)\s*$"#
        )
        let inodeHeader = try! NSRegularExpression(pattern: #"^Inode:\s*(\d+)\s*$"#)
        let attributeLine = try! NSRegularExpression(pattern: #"^\s*\[(0x[0-9A-Fa-f]+)\]\s*$"#)
        let matchLine = try! NSRegularExpression(pattern: #"^Inode\s+(\d+)\s+(/.*)$"#)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)

            if inodeHeader.firstMatch(in: line, range: range) != nil {
                currentAttribute = nil
                pending.removeAll()
                continue
            }

            if let match = attributeLine.firstMatch(in: line, range: range),
               let value = capture(match, 1, in: line) {
                currentAttribute = value
                pending.removeAll()
                continue
            }

            if let match = runLine.firstMatch(in: line, range: range),
               let first = capture(match, 2, in: line).flatMap(Int64.init),
               let last = capture(match, 3, in: line).flatMap(Int64.init) {
                if runs.count + pending.count >= maxRuns {
                    truncated = true
                    continue
                }
                pending.append((first, last))
                continue
            }

            if let match = matchLine.firstMatch(in: line, range: range),
               let inodeText = capture(match, 1, in: line).flatMap(Int.init),
               let path = capture(match, 2, in: line) {
                guard let pendingRun = pending.first else { continue }
                pending.removeFirst()
                runs.append(NTFSVolumeRun(
                    inode: inodeText,
                    path: path,
                    attribute: currentAttribute ?? "?",
                    firstLCN: pendingRun.first,
                    lastLCN: pendingRun.last
                ))
                continue
            }
        }

        return NTFSClusterMap(
            runs: runs,
            inodeCount: Set(runs.map(\.inode)).count,
            truncated: truncated
        )
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        _ index: Int,
        in text: String
    ) -> String? {
        guard index < match.numberOfRanges else { return nil }
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Attribution

public enum CopyFileIntegrity: String, Equatable, Sendable, Codable {
    case intact
    case overlapsBadExtent = "overlaps-bad-extent"
    case metadataDamaged = "metadata-damaged"
}

public enum CopyRunOwner: Equatable, Sendable {
    case file(path: String)
    case metadata(path: String)
    /// A metadata run whose directory is known, so its immediate children can
    /// be called `metadata-damaged` without claiming anything about other files.
    case directoryMetadata(path: String, directory: String)
    case unknown(path: String)
}

public enum CopyRunOwnership {
    /// The last path component is the attribute (`$DATA`, `$INDEX_ALLOCATION`…).
    /// A normal file's `$DATA` run belongs to that file; every `$` name, `.` or
    /// non-`$DATA` attribute is metadata.
    public static func owner(of run: NTFSVolumeRun) -> CopyRunOwner {
        let components = run.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let attribute = components.last, attribute.hasPrefix("$") else {
            return .unknown(path: run.path)
        }
        let parents = components.dropLast()
        if parents.isEmpty || parents == ["."] {
            return .metadata(path: run.path)
        }
        if parents.contains(where: { $0.hasPrefix("$") }) {
            return .metadata(path: run.path)
        }
        if attribute.hasPrefix("$DATA") {
            return .file(path: "/" + parents.joined(separator: "/"))
        }
        if attribute.hasPrefix("$INDEX_ALLOCATION"), parents.count == 1 {
            return .directoryMetadata(
                path: run.path,
                directory: "/" + parents.joined(separator: "/")
            )
        }
        return .metadata(path: run.path)
    }
}

public struct CopyAttribution: Equatable, Sendable {
    public let kind: String
    public let reason: String?
    public let integrity: [String: CopyFileIntegrity]
    public let metadataPaths: [String]
    public let unattributedRanges: [ClusterRange]
    public let badRanges: [ClusterRange]
    public let filesClaimed: Int
    public let filesOverlapping: Int
    public let filesMetadataDamaged: Int

    public init(
        kind: String,
        reason: String?,
        integrity: [String: CopyFileIntegrity],
        metadataPaths: [String],
        unattributedRanges: [ClusterRange],
        badRanges: [ClusterRange],
        filesClaimed: Int,
        filesOverlapping: Int,
        filesMetadataDamaged: Int
    ) {
        self.kind = kind
        self.reason = reason
        self.integrity = integrity
        self.metadataPaths = metadataPaths
        self.unattributedRanges = unattributedRanges
        self.badRanges = badRanges
        self.filesClaimed = filesClaimed
        self.filesOverlapping = filesOverlapping
        self.filesMetadataDamaged = filesMetadataDamaged
    }

    public static func unavailable(reason: String, badRanges: [ClusterRange] = []) -> CopyAttribution {
        CopyAttribution(
            kind: "none",
            reason: reason,
            integrity: [:],
            metadataPaths: [],
            unattributedRanges: [],
            badRanges: badRanges,
            filesClaimed: 0,
            filesOverlapping: 0,
            filesMetadataDamaged: 0
        )
    }
}

/// The local intersection of the mapfile's bad clusters with the one-pass
/// `ntfscluster` run map. Extents are never merged into a min-max span: a file
/// in a good gap between two bad extents must stay `intact`.
public enum CopyAttributionEngine {
    public static func attribute(
        badExtents: [ByteRange],
        partitionOffset: Int64,
        clusterSize: Int,
        volumeClusters: Int64?,
        runs: [NTFSVolumeRun],
        filePaths: [String]
    ) -> CopyAttribution {
        let badRanges = badExtents.compactMap {
            CopyExtentMath.clusterRange(
                for: $0,
                partitionOffset: partitionOffset,
                clusterSize: clusterSize,
                volumeClusters: volumeClusters
            )
        }

        let sortedRuns = runs
            .compactMap { run -> (range: ClusterRange, run: NTFSVolumeRun)? in
                guard let range = run.range else { return nil }
                return (range, run)
            }
            .sorted { $0.range < $1.range }

        // Every file gets a claim only because the run map succeeded: the
        // default is `intact`, and an intersection upgrades it. When the pass
        // is unavailable the CLI never calls this function, so no file is
        // labelled `unknown`.
        var integrity: [String: CopyFileIntegrity] = [:]
        for file in filePaths where integrity[file] == nil {
            integrity[file] = .intact
        }
        var metadataPaths: Set<String> = []
        var metadataDirectories: Set<String> = []
        var unattributed: [ClusterRange] = []

        for bad in badRanges {
            var matched = false
            for index in candidateIndices(for: bad, in: sortedRuns) {
                let entry = sortedRuns[index]
                guard entry.range.intersects(bad) else { continue }
                matched = true
                switch CopyRunOwnership.owner(of: entry.run) {
                case .file(let path):
                    // Data damage outranks a metadata note for the same file.
                    integrity[path] = .overlapsBadExtent
                case .directoryMetadata(let path, let directory):
                    metadataPaths.insert(path)
                    metadataDirectories.insert(directory)
                case .metadata(let path):
                    metadataPaths.insert(path)
                case .unknown(let path):
                    metadataPaths.insert(path)
                }
            }
            if !matched { unattributed.append(bad) }
        }

        // A damaged directory index is the one metadata case we can localise:
        // its immediate children may have lost their entry. Files are only
        // called `metadata-damaged`, never `overlaps-bad-extent`, for this.
        for file in filePaths {
            let parent = parentPath(of: file)
            guard metadataDirectories.contains(parent) else { continue }
            if integrity[file] != .overlapsBadExtent {
                integrity[file] = .metadataDamaged
            }
        }

        let overlapping = integrity.values.filter { $0 == .overlapsBadExtent }.count
        let metadataDamaged = integrity.values.filter { $0 == .metadataDamaged }.count
        return CopyAttribution(
            kind: "ntfscluster",
            reason: nil,
            integrity: integrity,
            metadataPaths: metadataPaths.sorted(),
            unattributedRanges: unattributed,
            badRanges: badRanges,
            filesClaimed: filePaths.count,
            filesOverlapping: overlapping,
            filesMetadataDamaged: metadataDamaged
        )
    }

    /// Runs are disjoint and sorted by first LCN, so the binary search finds the
    /// last run starting at/before the bad range, then only a handful of
    /// backwards neighbours can still intersect it.
    private static func candidateIndices(
        for bad: ClusterRange,
        in runs: [(range: ClusterRange, run: NTFSVolumeRun)]
    ) -> [Int] {
        guard !runs.isEmpty else { return [] }
        var low = 0
        var high = runs.count - 1
        var lastStartingBefore = -1
        while low <= high {
            let middle = (low + high) / 2
            if runs[middle].range.first <= bad.last {
                lastStartingBefore = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard lastStartingBefore >= 0 else { return [] }
        var indices: [Int] = []
        var index = lastStartingBefore
        while index >= 0, runs[index].range.last >= bad.first {
            indices.append(index)
            index -= 1
            // A non-overlapping neighbour that ends before the bad range means
            // every earlier run also ends before it.
            if index >= 0, runs[index].range.last < bad.first { break }
        }
        return indices
    }

    private static func parentPath(of path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 1 else { return "/" }
        return "/" + components.dropLast().joined(separator: "/")
    }
}

// MARK: - Paths

public enum CopyPathRules {
    /// A transferred name is a volume path. It may lose one leading `/`, but
    /// every component must be a real name: `.`/`..`, NUL and an embedded
    /// leading slash are refusals, never sanitised into something else.
    public static func refusal(_ path: String) -> String? {
        guard !path.isEmpty else { return "the path is empty" }
        guard !path.contains("\0") else { return "the path contains a NUL byte" }
        var relative = path
        if relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return "the path is the volume root, not a file" }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty { return "the path has an empty component" }
            if component == "." { return "the path has a '.' component" }
            if component == ".." { return "the path has a '..' component (path traversal)" }
            if component.contains("/") { return "the path component contains '/'" }
        }
        return nil
    }

    public static func isSafe(_ path: String) -> Bool { refusal(path) == nil }

    /// The destination-relative spelling of a volume path.
    public static func relative(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    public static func volumePath(directory: String?, name: String) -> String {
        if let directory, directory != "/" {
            return directory + "/" + name
        }
        return "/" + name
    }
}

// MARK: - Limits

public enum CopyLimits {
    /// A cap on the file list, not on the volume: crossing it makes the copy
    /// partial and is reported, never silently ignored.
    public static let maxEntries = 10_000
    /// One file larger than this is not copied (the tool buffers its stdout).
    public static let maxFileBytes: Int64 = 1_073_741_824
    /// The whole run's byte budget.
    public static let maxTotalBytes: Int64 = 8_589_934_592
    /// The whole run's wall-clock budget, independent of per-call timeouts.
    public static let totalTimeout: TimeInterval = 1_800
}

// MARK: - Manifest

public struct CopyManifestEntry: Equatable, Sendable {
    public let path: String
    public let sizeBytes: Int64?
    public let sha256Read: String?
    public let sha256Written: String?
    public let integrity: CopyFileIntegrity?
    public let attribution: String?
    public let status: String
    public let note: String?

    public init(
        path: String,
        sizeBytes: Int64?,
        sha256Read: String?,
        sha256Written: String?,
        integrity: CopyFileIntegrity?,
        attribution: String?,
        status: String,
        note: String?
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256Read = sha256Read
        self.sha256Written = sha256Written
        self.integrity = integrity
        self.attribution = attribution
        self.status = status
        self.note = note
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "path": path,
            "status": status,
        ]
        object["size_bytes"] = sizeBytes.map { $0 } ?? NSNull()
        object["sha256_read"] = sha256Read ?? NSNull()
        object["sha256_written"] = sha256Written ?? NSNull()
        if let integrity { object["integrity"] = integrity.rawValue }
        if let attribution { object["attribution"] = attribution }
        if let note { object["note"] = note }
        return object
    }
}

public struct CopyManifest: Equatable, Sendable {
    public static let schema = "disktriage.copy/1"
    public static let version = 1
    public static let tool = "disktriage"
    public static let toolVersion = "0.1.0"

    public struct ImageInfo: Equatable, Sendable {
        public let path: String
        public let sizeBytes: Int64
        public let sha256: String?
        public let sha256Note: String

        public init(path: String, sizeBytes: Int64, sha256: String?, sha256Note: String) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
            self.sha256Note = sha256Note
        }
    }

    public struct SourceInfo: Equatable, Sendable {
        public let mapfile: String?
        public let unreadableExtents: Int?
        public let unreadableBytes: Int64?
        public let limitBytes: Int64?
        public let remainingBytes: Int64?

        public init(
            mapfile: String?,
            unreadableExtents: Int?,
            unreadableBytes: Int64?,
            limitBytes: Int64?,
            remainingBytes: Int64?
        ) {
            self.mapfile = mapfile
            self.unreadableExtents = unreadableExtents
            self.unreadableBytes = unreadableBytes
            self.limitBytes = limitBytes
            self.remainingBytes = remainingBytes
        }
    }

    public struct DamageInfo: Equatable, Sendable {
        public let status: String
        public let unreadableExtents: Int?
        public let unreadableBytes: Int64?
        public let limitBytes: Int64?
        public let note: String?

        public init(
            status: String,
            unreadableExtents: Int?,
            unreadableBytes: Int64?,
            limitBytes: Int64?,
            note: String?
        ) {
            self.status = status
            self.unreadableExtents = unreadableExtents
            self.unreadableBytes = unreadableBytes
            self.limitBytes = limitBytes
            self.note = note
        }
    }

    public struct CopyInfo: Equatable, Sendable {
        public let status: String
        public let filesCopied: Int
        public let filesFailed: Int
        public let bytesRead: Int64
        public let bytesWritten: Int64
        public let hashesAgree: Bool
        public let manifestSHA256: String

        public init(
            status: String,
            filesCopied: Int,
            filesFailed: Int,
            bytesRead: Int64,
            bytesWritten: Int64,
            hashesAgree: Bool,
            manifestSHA256: String
        ) {
            self.status = status
            self.filesCopied = filesCopied
            self.filesFailed = filesFailed
            self.bytesRead = bytesRead
            self.bytesWritten = bytesWritten
            self.hashesAgree = hashesAgree
            self.manifestSHA256 = manifestSHA256
        }
    }

    public let createdAt: String
    public let image: ImageInfo
    public let source: SourceInfo
    public let damage: DamageInfo
    public let attribution: CopyAttribution
    public let copy: CopyInfo
    public let entries: [CopyManifestEntry]
    public let notes: [String]

    public init(
        createdAt: String,
        image: ImageInfo,
        source: SourceInfo,
        damage: DamageInfo,
        attribution: CopyAttribution,
        copy: CopyInfo,
        entries: [CopyManifestEntry],
        notes: [String]
    ) {
        self.createdAt = createdAt
        self.image = image
        self.source = source
        self.damage = damage
        self.attribution = attribution
        self.copy = copy
        self.entries = entries
        self.notes = notes
    }

    public func jsonObject() -> [String: Any] {
        var sourceObject: [String: Any] = [:]
        sourceObject["mapfile"] = source.mapfile ?? NSNull()
        sourceObject["unreadable_extents"] = source.unreadableExtents.map { $0 } ?? NSNull()
        sourceObject["unreadable_bytes"] = source.unreadableBytes.map { $0 } ?? NSNull()
        sourceObject["limit_bytes"] = source.limitBytes.map { $0 } ?? NSNull()
        sourceObject["remaining_bytes"] = source.remainingBytes.map { $0 } ?? NSNull()

        var damageObject: [String: Any] = [
            "scope": "volume",
            "status": damage.status,
        ]
        damageObject["unreadable_extents"] = damage.unreadableExtents.map { $0 } ?? NSNull()
        damageObject["unreadable_bytes"] = damage.unreadableBytes.map { $0 } ?? NSNull()
        damageObject["limit_bytes"] = damage.limitBytes.map { $0 } ?? NSNull()
        damageObject["note"] = damage.note ?? NSNull()

        var attributionObject: [String: Any] = [
            "kind": attribution.kind,
            "files_claimed": attribution.filesClaimed,
            "files_overlapping": attribution.filesOverlapping,
            "files_metadata_damaged": attribution.filesMetadataDamaged,
            "metadata_paths": attribution.metadataPaths,
            "unattributed_ranges": attribution.unattributedRanges.map {
                [
                    "first_cluster": $0.first,
                    "last_cluster": $0.last,
                    "clusters": $0.count,
                ] as [String: Any]
            },
        ]
        attributionObject["reason"] = attribution.reason ?? NSNull()

        var copyObject: [String: Any] = [
            "status": copy.status,
            "files_copied": copy.filesCopied,
            "files_failed": copy.filesFailed,
            "bytes_read": copy.bytesRead,
            "bytes_written": copy.bytesWritten,
            "hashes_agree": copy.hashesAgree,
            "manifest_sha256": copy.manifestSHA256,
        ]

        let imageObject: [String: Any] = [
            "path": image.path,
            "size_bytes": image.sizeBytes,
        ]

        return [
            "schema": Self.schema,
            "version": Self.version,
            "tool": Self.tool,
            "tool_version": Self.toolVersion,
            "created_at": createdAt,
            "image": imageObject,
            "image_sha256": image.sha256 ?? NSNull(),
            "image_sha256_note": image.sha256Note,
            "source": sourceObject,
            "damage": damageObject,
            "attribution": attributionObject,
            "copy": copyObject,
            "files": entries.map { $0.jsonObject() },
            "notes": notes,
        ]
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// The manifest-level digest is a hash of the entries, so a reader can
    /// detect a changed per-file list without re-hashing the data. The hex
    /// value is supplied by the caller (CryptoKit lives in the CLI, not here).
    public static func digestText(entries: [CopyManifestEntry]) -> String {
        entries.map { entry in
            [
                entry.path,
                entry.sizeBytes.map(String.init) ?? "-",
                entry.sha256Read ?? "-",
                entry.sha256Written ?? "-",
                entry.status,
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
