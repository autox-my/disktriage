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
    /// The byte range the accounting is limited to, `nil` for a full image.
    /// `ddrescue -s` leaves the untried tail ending at `Int64.max`, so a
    /// partial image is measured only inside `[0, rangeBytes)` (REQ-0108).
    public let rangeBytes: Int64?

    public init(
        rescuedBytes: Int64,
        badBytes: Int64,
        nonTriedBytes: Int64,
        nonTrimmedBytes: Int64,
        nonScrapedBytes: Int64,
        finished: Bool,
        pass: Int?,
        extents: [MapfileExtent],
        rangeBytes: Int64? = nil
    ) {
        self.rescuedBytes = rescuedBytes
        self.badBytes = badBytes
        self.nonTriedBytes = nonTriedBytes
        self.nonTrimmedBytes = nonTrimmedBytes
        self.nonScrapedBytes = nonScrapedBytes
        self.finished = finished
        self.pass = pass
        self.extents = extents
        self.rangeBytes = rangeBytes
    }

    /// Extents that failed during copying (`*`, non-trimmed) or were trimmed
    /// but not scraped (`/`, non-scraped). Both have read errors on record but
    /// are not yet isolated, so a later trim/scrape pass may shrink them. They
    /// are deliberately not `bad`: `-` means ddrescue confirmed the block is
    /// unreadable (GNU ddrescue 1.30 manual, mapfile statuses).
    public var failedExtents: [MapfileExtent] {
        extents.filter { $0.status == "*" || $0.status == "/" }
    }

    /// `*` plus `/` bytes: read errors seen, not yet confirmed bad.
    public var failedBytes: Int64 { nonTrimmedBytes + nonScrapedBytes }

    /// `-` extents: ddrescue gave up on these and the image has them
    /// zero-filled. A resume does not retry them.
    public var badExtents: [MapfileExtent] {
        extents.filter { $0.status == "-" }
    }

    /// Extents ddrescue has not finished: non-tried, non-trimmed, non-scraped
    /// and bad sectors. These are what a resume would still attempt.
    ///
    /// Inside a partial range, bad bytes are already accounted as `bad` and are
    /// not "remaining to try", so `rescued + bad + remaining == rangeBytes`.
    public var remainingExtents: [MapfileExtent] {
        let candidates = extents.filter { !$0.isRescued && $0.size > 0 }
        guard rangeBytes != nil else { return candidates }
        return candidates.filter { $0.status != "-" }
    }

    public var remainingBytes: Int64 {
        if let rangeBytes {
            return max(0, rangeBytes - rescuedBytes - badBytes)
        }
        return remainingExtents.reduce(0) { $0 + $1.size }
    }

    /// Nothing is left to try. Bad sectors still count as remaining: they are
    /// zero-filled in the image, not rescued.
    public var isComplete: Bool { remainingBytes == 0 }

    public var rescuedFraction: Double {
        if let rangeBytes, rangeBytes > 0 {
            return Double(rescuedBytes) / Double(rangeBytes)
        }
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
    /// Parses a mapfile. `limitBytes` is the partial image's limit: when it is
    /// present every extent is clipped to `[0, limitBytes)` and the accounting
    /// is computed inside that range. `nil` is a full image and keeps the
    /// mapfile's own extents, including an unbounded tail (REQ-0108).
    public static func parse(_ text: String, limitBytes: Int64? = nil) -> MapfileSnapshot? {
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

        if let limitBytes {
            extents = clip(extents, to: limitBytes)
        }

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
            extents: extents,
            rangeBytes: limitBytes
        )
    }

    /// Clips every extent to `[0, limit)`; an extent that starts at or after
    /// the limit (or ends at or before zero) is dropped. A partial image's
    /// `-s` leaves the untried tail ending at `Int64.max`, so this is what
    /// keeps `remaining` and the percentage finite (REQ-0108).
    private static func clip(_ extents: [MapfileExtent], to limit: Int64) -> [MapfileExtent] {
        guard limit > 0 else { return [] }
        return extents.compactMap { extent in
            let start = max(0, extent.position)
            let end = min(extent.end, limit)
            guard end > start else { return nil }
            return MapfileExtent(position: start, size: end - start, status: extent.status)
        }
    }

    private static func hex(_ field: Substring) -> Int64? {
        var value = field
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            value = value.dropFirst(2)
        }
        return Int64(value, radix: 16)
    }
}
