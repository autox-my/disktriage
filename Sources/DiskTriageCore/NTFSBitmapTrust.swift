import Foundation

/// What a stage-0 `$Bitmap` read can and cannot vouch for (diskdoctor.md §8,
/// "Allocation-aware order for NTFS"). A mapfile row that is not `+` is not
/// evidence: the image holds zeroes there, and a zero bitmap bit reads as
/// "free". Those bitmap bytes, and the eight clusters each byte describes, are
/// UNKNOWN allocation — never free.
///
/// This is pure: the caller reads the main mapfile and the `$Bitmap` data runs,
/// and passes both in device byte coordinates. The bitmap data runs are in
/// **stream order** (VCN order), so the byte index of a run is the sum of the
/// sizes of the runs before it.
public enum NTFSBitmapTrust {
    /// The untrustworthy part of one `$Bitmap`.
    public struct Unreadable: Equatable, Sendable {
        /// Untrustworthy intervals in **bitmap-stream byte order**: byte 0 is
        /// the bitmap's first bit, wherever that byte sits on the device.
        public let byteRanges: [ByteRange]
        /// The volume-relative clusters those bytes describe, coalesced and
        /// clipped to the volume's cluster count.
        public let clusters: [ClusterRange]
        /// The volume's cluster size, so `unknownBytes` needs no second input.
        public let clusterBytes: Int64

        public init(
            byteRanges: [ByteRange],
            clusters: [ClusterRange],
            clusterBytes: Int64
        ) {
            self.byteRanges = byteRanges
            self.clusters = clusters
            self.clusterBytes = clusterBytes
        }

        /// No untrustworthy byte: the bitmap was read in full.
        public static let none = Unreadable(byteRanges: [], clusters: [], clusterBytes: 0)

        /// Unreadable bitmap bytes, the number the report prints.
        public var bitmapBytes: Int64 { byteRanges.reduce(0) { $0 + $1.size } }

        /// Number of untrustworthy bitmap byte extents.
        public var extentCount: Int { byteRanges.count }

        public var clusterCount: Int64 { clusters.reduce(0) { $0 + $1.count } }

        /// Device bytes of allocation this report cannot vouch for.
        public var unknownBytes: Int64 { clusterCount * clusterBytes }

        public var isEmpty: Bool { byteRanges.isEmpty }
    }

    /// Intersects the bitmap data runs with the ranges the main mapfile did not
    /// finish and maps the hits back through the bitmap's stream order.
    ///
    /// A bitmap byte covers eight clusters (one bit each), least-significant
    /// bit first, so bitmap byte `n` describes clusters `8n ... 8n + 7`. The
    /// last range is clipped to `totalClusters`, because the `$Bitmap`'s
    /// trailing padding bits are not clusters.
    public static func unreadable(
        bitmapRuns: [ByteRange],
        unfinished: [ByteRange],
        clusterBytes: Int64,
        totalClusters: Int64
    ) -> Unreadable {
        let holes = coalesce(unfinished)
        var streamRanges: [ByteRange] = []
        var streamOffset: Int64 = 0

        // Runs stay in stream order: a sort or merge by device position would
        // assign a byte to the wrong eight clusters after a fragmented bitmap.
        for run in bitmapRuns where run.size > 0 {
            for hole in holes {
                // Distance arithmetic, not `end`: a full-device mapfile's
                // untried tail can put `position + size` past Int64.max.
                let start = max(run.position, hole.position)
                let runRemaining = run.size - (start - run.position)
                let holeRemaining = hole.size - (start - hole.position)
                guard runRemaining > 0, holeRemaining > 0 else { continue }
                let length = min(runRemaining, holeRemaining)
                streamRanges.append(ByteRange(
                    position: streamOffset + (start - run.position),
                    size: length
                ))
            }
            streamOffset += run.size
        }

        var clusters: [ClusterRange] = []
        if totalClusters > 0 {
            for range in coalesce(streamRanges) {
                let (firstBits, firstOverflow) =
                    range.position.multipliedReportingOverflow(by: 8)
                let (endBits, endOverflow) = range.end.multipliedReportingOverflow(by: 8)
                guard !firstOverflow, !endOverflow else { continue }
                let first = max(0, firstBits)
                let last = min(endBits - 1, totalClusters - 1)
                guard last >= first,
                      let clusterRange = ClusterRange(first: first, last: last)
                else { continue }
                clusters.append(clusterRange)
            }
        }

        return Unreadable(
            byteRanges: coalesce(streamRanges),
            clusters: coalesce(clusters),
            clusterBytes: clusterBytes
        )
    }

    /// Sorts and coalesces touching or overlapping byte extents. One read of
    /// two adjacent rows is one extent.
    static func coalesce(_ extents: [ByteRange]) -> [ByteRange] {
        let sorted = extents.filter { $0.size > 0 }.sorted {
            $0.position == $1.position ? $0.size < $1.size : $0.position < $1.position
        }
        var merged: [ByteRange] = []
        for extent in sorted {
            if let last = merged.last, extent.position <= last.end {
                let end = max(last.end, extent.end)
                merged[merged.count - 1] = ByteRange(
                    position: last.position,
                    size: end - last.position
                )
            } else {
                merged.append(extent)
            }
        }
        return merged
    }

    /// Sorts and coalesces touching or overlapping cluster intervals.
    static func coalesce(_ ranges: [ClusterRange]) -> [ClusterRange] {
        let sorted = ranges.sorted()
        var merged: [ClusterRange] = []
        for range in sorted {
            if let last = merged.last, range.first <= last.last + 1 {
                if let extended = ClusterRange(first: last.first, last: max(last.last, range.last)) {
                    merged[merged.count - 1] = extended
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
