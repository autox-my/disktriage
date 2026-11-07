import Foundation

/// The volume geometry `ntfsinfo -m` prints. Every field is optional because a
/// truncated or damaged volume can print a partial record; `nil` is unknown,
/// never zero.
public struct NTFSVolumeInfo: Equatable, Sendable {
    public let volumeName: String?
    public let volumeVersion: String?
    public let volumeFlags: String?
    public let sectorSize: Int?
    public let clusterSize: Int?
    public let indexBlockSize: Int?
    public let volumeSizeClusters: Int64?
    public let freeClusters: Int64?

    public init(
        volumeName: String?,
        volumeVersion: String?,
        volumeFlags: String?,
        sectorSize: Int?,
        clusterSize: Int?,
        indexBlockSize: Int?,
        volumeSizeClusters: Int64?,
        freeClusters: Int64?
    ) {
        self.volumeName = volumeName
        self.volumeVersion = volumeVersion
        self.volumeFlags = volumeFlags
        self.sectorSize = sectorSize
        self.clusterSize = clusterSize
        self.indexBlockSize = indexBlockSize
        self.volumeSizeClusters = volumeSizeClusters
        self.freeClusters = freeClusters
    }
}

/// Parses the `key: value` lines of `ntfsinfo -m`. It is deliberately tolerant:
/// the caller's status is the tool's exit code, and this value is the readable
/// detail beside it.
public enum NTFSVolumeInfoParser {
    public static func parse(_ text: String) -> NTFSVolumeInfo? {
        var fields: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
        }

        guard fields.keys.contains(where: {
            ["Volume Name", "Cluster Size", "Volume Size in Clusters", "Volume Version"]
                .contains($0)
        }) else {
            return nil
        }

        return NTFSVolumeInfo(
            volumeName: fields["Volume Name"],
            volumeVersion: fields["Volume Version"],
            volumeFlags: fields["Volume Flags"],
            sectorSize: integer(fields["Sector Size"]),
            clusterSize: integer(fields["Cluster Size"]),
            indexBlockSize: integer(fields["Index Block Size"]),
            volumeSizeClusters: integer64(fields["Volume Size in Clusters"]),
            freeClusters: integer64(fields["Free Clusters"])
        )
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value, let number = Int(value.split(separator: " ").first ?? "") else { return nil }
        return number
    }

    private static func integer64(_ value: String?) -> Int64? {
        guard let value, let first = value.split(separator: " ").first, let number = Int64(first) else {
            return nil
        }
        return number
    }
}

/// One line of `ntfsls` output. `directory` is the listing header the entry was
/// under (`/docs`), or `nil` for a flat root listing.
public struct NTFSListingEntry: Equatable, Sendable {
    public let name: String
    public let directory: String?
    public let inode: Int64?
    public let sizeBytes: Int64?

    public init(name: String, directory: String?, inode: Int64?, sizeBytes: Int64?) {
        self.name = name
        self.directory = directory
        self.inode = inode
        self.sizeBytes = sizeBytes
    }
}

public struct NTFSListing: Equatable, Sendable {
    public let entries: [NTFSListingEntry]
    public let directoryCount: Int
    /// The parse or the process output was capped. A capped listing is not a
    /// complete answer (the spike's `ntfsls` exits 0 on partial output).
    public let truncated: Bool

    public init(entries: [NTFSListingEntry], directoryCount: Int, truncated: Bool) {
        self.entries = entries
        self.directoryCount = directoryCount
        self.truncated = truncated
    }
}

/// Parses `ntfsls -l` (size/date/name) and `ntfsls -R` (directory headers and
/// names). The real formats are recorded in `Tests/Fixtures/ntfsls-*.txt`.
/// `.` and `..` are structural, not content, so they are dropped.
public enum NTFSListingParser {
    public static let defaultMaxEntries = 2000

    public static func parse(_ text: String, maxEntries: Int = defaultMaxEntries) -> NTFSListing {
        var entries: [NTFSListingEntry] = []
        var directory: String?
        var directoryCount = 0
        var truncated = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("/") && line.hasSuffix(":") {
                directory = String(line.dropLast())
                directoryCount += 1
                continue
            }

            guard let parsed = parseEntry(line, directory: directory) else { continue }
            guard parsed.name != "." && parsed.name != ".." else { continue }

            if entries.count >= maxEntries {
                truncated = true
                continue
            }
            entries.append(parsed)
        }

        return NTFSListing(entries: entries, directoryCount: directoryCount, truncated: truncated)
    }

    private static let months: Set<String> = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func parseEntry(_ line: String, directory: String?) -> NTFSListingEntry? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)

        // Long form: [inode] size Mon day time year name...
        if tokens.count >= 6, let monthIndex = tokens.prefix(3).firstIndex(where: { months.contains($0) }) {
            guard monthIndex + 4 < tokens.count else { return nil }
            let name = tokens[(monthIndex + 4)...].joined(separator: " ")
            guard !name.isEmpty else { return nil }

            let size: Int64?
            let inode: Int64?
            if monthIndex >= 2, let inodeValue = Int64(tokens[monthIndex - 2]),
               let sizeValue = Int64(tokens[monthIndex - 1]) {
                inode = inodeValue
                size = sizeValue
            } else if monthIndex >= 1, let sizeValue = Int64(tokens[monthIndex - 1]) {
                inode = nil
                size = sizeValue
            } else {
                inode = nil
                size = nil
            }
            return NTFSListingEntry(name: name, directory: directory, inode: inode, sizeBytes: size)
        }

        // Recursive name-only form: one path component per line.
        if tokens.count == 1 {
            return NTFSListingEntry(name: tokens[0], directory: directory, inode: nil, sizeBytes: nil)
        }
        return nil
    }
}
