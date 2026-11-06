import Foundation

/// One extent row of a GNU ddrescue mapfile.
public struct MapfileExtent: Equatable, Sendable {
    public let position: Int64
    public let size: Int64
    /// `+` rescued, `-` bad sector, `?` non-tried, `*` non-trimmed,
    /// `/` non-scraped.
    public let status: Character

    public init(position: Int64, size: Int64, status: Character) {
        self.position = position
        self.size = size
        self.status = status
    }

    public var end: Int64 { position + size }
    public var isRescued: Bool { status == "+" }
}

/// What a mapfile says at one moment. `nil` from the parser means the file is
/// absent or not a mapfile yet; a zero-byte rescue is a measurement, an absent
/// file is not (diskdoctor.md §2.3).
public struct MapfileSnapshot: Equatable, Sendable {
    public let rescuedBytes: Int64
    public let badBytes: Int64
    public let nonTriedBytes: Int64
    public let nonTrimmedBytes: Int64
    public let nonScrapedBytes: Int64
    public let finished: Bool
    public let pass: Int?
    public let extents: [MapfileExtent]

    public init(
        rescuedBytes: Int64,
        badBytes: Int64,
        nonTriedBytes: Int64,
        nonTrimmedBytes: Int64,
        nonScrapedBytes: Int64,
        finished: Bool,
        pass: Int?,
        extents: [MapfileExtent]
    ) {
        self.rescuedBytes = rescuedBytes
        self.badBytes = badBytes
        self.nonTriedBytes = nonTriedBytes
        self.nonTrimmedBytes = nonTrimmedBytes
        self.nonScrapedBytes = nonScrapedBytes
        self.finished = finished
        self.pass = pass
        self.extents = extents
    }

    /// Extents ddrescue has not finished: non-tried, non-trimmed, non-scraped
    /// and bad sectors. These are what a resume would still attempt.
    public var remainingExtents: [MapfileExtent] {
        extents.filter { !$0.isRescued && $0.size > 0 }
    }

    public var remainingBytes: Int64 {
        remainingExtents.reduce(0) { $0 + $1.size }
    }

    /// Nothing is left to try. Bad sectors still count as remaining: they are
    /// zero-filled in the image, not rescued.
    public var isComplete: Bool { remainingBytes == 0 }

    public var rescuedFraction: Double {
        let total = rescuedBytes + remainingBytes
        guard total > 0 else { return 0 }
        return Double(rescuedBytes) / Double(total)
    }
}

/// A strict parser for the GNU ddrescue mapfile format (v1.30). It is pure:
/// the caller reads the file, so every rule here is testable without a device.
///
/// ```
/// # current_pos  current_status  current_pass
/// 0x000F0000     +               1
/// #      pos        size  status
/// 0x00000000  0x00100000  +
/// 0x00100000  0x00100000  ?
/// ```
public enum DdrescueMapfile {
    public static func parse(_ text: String) -> MapfileSnapshot? {
        var finished = false
        var pass: Int?
        var sawExtentHeader = false
        var extents: [MapfileExtent] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if line == "# Finished" { finished = true }
                if line.hasPrefix("# current_pos") {
                    // The next non-comment line is the current position row.
                    continue
                }
                let fields = line.dropFirst().split(whereSeparator: \.isWhitespace)
                if fields.count >= 3,
                   fields[0] == "pos", fields[1] == "size", fields[2] == "status" {
                    sawExtentHeader = true
                }
                continue
            }

            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3 else { return nil }

            if !sawExtentHeader {
                // The current-position row: position, current status, pass.
                guard pass == nil, let value = Int(fields[2]) else { return nil }
                pass = value
                continue
            }

            guard let position = hex(fields[0]),
                  let size = hex(fields[1]),
                  let status = fields[2].first
            else {
                return nil
            }
            guard "+-?*/".contains(status) else { return nil }
            extents.append(MapfileExtent(position: position, size: size, status: status))
        }

        guard sawExtentHeader else { return nil }

        func total(_ status: Character) -> Int64 {
            extents
                .filter { $0.status == status }
                .reduce(0) { $0 + $1.size }
        }

        return MapfileSnapshot(
            rescuedBytes: total("+"),
            badBytes: total("-"),
            nonTriedBytes: total("?"),
            nonTrimmedBytes: total("*"),
            nonScrapedBytes: total("/"),
            finished: finished,
            pass: pass,
            extents: extents
        )
    }

    private static func hex(_ field: Substring) -> Int64? {
        var value = field
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            value = value.dropFirst(2)
        }
        return Int64(value, radix: 16)
    }
}
