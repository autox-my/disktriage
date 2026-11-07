import Foundation
import DiskTriageCore

// The `--scope-report` mode of `disktriage image` (diskdoctor.md §8): run the
// allocation-aware stage 0 only, then say how much of the volume is allocated.
// The numbers come from the parsed `$Bitmap`, never from the read extents: a
// report that could not parse the bitmap must not invent an allocation.

/// One stage-0 scope report. The twelve reported values are the bitmap's view
/// of the volume; `limitBytes` is the `--limit` composition, reported beside
/// them rather than folded in.
struct ScopeReport: Equatable, Sendable {
    let geometrySource: String
    let clusterBytes: Int64
    let totalClusters: Int64
    let usedClusters: Int64
    let freeClusters: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let usedExtents: Int
    let mftBytes: Int64
    let etaLowSeconds: Double?
    let etaHighSeconds: Double?
    let etaBasis: String
    /// The partial limit in device bytes, `nil` for a full device.
    let limitBytes: Int64?
    /// The used bytes that fall inside `[0, limit)`, `nil` without a limit.
    let usedBytesInsideLimit: Int64?

    /// The sidecar and the JSON share this value, so their keys cannot drift.
    var sidecarValue: ImageSidecarScopeReport {
        ImageSidecarScopeReport(
            geometrySource: geometrySource,
            clusterBytes: clusterBytes,
            totalClusters: totalClusters,
            usedClusters: usedClusters,
            freeClusters: freeClusters,
            usedBytes: usedBytes,
            freeBytes: freeBytes,
            usedExtents: usedExtents,
            mftBytes: mftBytes,
            etaLowSeconds: etaLowSeconds,
            etaHighSeconds: etaHighSeconds,
            etaBasis: etaBasis
        )
    }
}

/// Builds the report from the stage-0 domain. The ETA applies the existing bus
/// assumption to the **used** bytes, which is what stage 1 reads; the
/// failed-block caveat stays text.
func makeScopeReport(
    stage0: Stage0Domain,
    source: ImageSource,
    limitBytes: Int64?
) -> ScopeReport {
    let clusterBytes = Int64(stage0.geometry.clusterSize)
    let totalClusters = stage0.geometry.totalClusters
    let usedClusters = stage0.domain.usedClusters.reduce(0) { $0 + $1.count }
    let freeClusters = max(0, totalClusters - usedClusters)
    let usedBytes = usedClusters * clusterBytes
    let freeBytes = freeClusters * clusterBytes

    let bus = assumedBusSpeed(bus: source.bus)
    let eta = etaRange(
        deviceBytes: usedBytes,
        lowBytesPerSecond: bus.lowBytesPerSecond,
        highBytesPerSecond: bus.highBytesPerSecond,
        basis: bus.basis
    )

    let usedInsideLimit = limitBytes.map { limit in
        clipExtents(stage0.domain.used, to: limit).reduce(0) { $0 + $1.size }
    }

    return ScopeReport(
        geometrySource: stage0.geometrySource.rawValue,
        clusterBytes: clusterBytes,
        totalClusters: totalClusters,
        usedClusters: usedClusters,
        freeClusters: freeClusters,
        usedBytes: usedBytes,
        freeBytes: freeBytes,
        usedExtents: stage0.domain.usedClusters.count,
        mftBytes: stage0.mftBytes,
        etaLowSeconds: eta?.lowSeconds,
        etaHighSeconds: eta?.highSeconds,
        etaBasis: bus.basis,
        limitBytes: limitBytes,
        usedBytesInsideLimit: usedInsideLimit
    )
}

// MARK: - Human

func renderScopeReportTTY(_ report: ScopeReport) -> String {
    var lines: [String] = []
    lines.append(scopeField("SCOPE", "stage 0 only (--scope-report): the metadata read; "
        + "no used or free clusters were read"))
    lines.append(scopeField("GEOMETRY", "\(report.geometrySource) boot sector"))
    lines.append(scopeField("CLUSTER", "\(report.clusterBytes) bytes"))
    lines.append(scopeField(
        "CLUSTERS",
        "total \(report.totalClusters) · used \(report.usedClusters) · free \(report.freeClusters)"
    ))
    lines.append(scopeField(
        "BYTES",
        "used \(scopeBytes(report.usedBytes)) · free \(scopeBytes(report.freeBytes))"
    ))
    lines.append(scopeField("EXTENTS", "\(report.usedExtents) used extents"))
    lines.append(scopeField("$MFT", "\(scopeBytes(report.mftBytes)); inside the used bytes"))

    if let low = report.etaLowSeconds, let high = report.etaHighSeconds {
        lines.append(scopeField(
            "ETA",
            "stage 1 (used clusters + metadata) \(scopeDurationRange(low: low, high: high)) "
                + "at \(report.etaBasis)"
        ))
    } else {
        lines.append(scopeField("ETA", "not computable: the used byte count is zero or unknown"))
    }
    lines.append(scopeField(
        "NOTE",
        "a failed block costs about 48 s each on macOS when it is retried; that is not "
            + "in the ETA, and the ETA is a range, not a promise"
    ))
    if let limit = report.limitBytes {
        lines.append(scopeField(
            "LIMIT",
            "the first \(limit) of the device; used bytes inside the limit: "
                + "\(report.usedBytesInsideLimit ?? 0) of \(report.usedBytes)"
        ))
    }
    lines.append(scopeField(
        "RESULT",
        "scope report complete; stage 1 and stage 2 were not run"
    ))
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - JSON

func renderScopeReportJSON(_ report: ScopeReport, image: String, mapfile: String, sidecar: String) -> String {
    var scope: [String: Any] = [
        "geometry_source": report.geometrySource,
        "cluster_bytes": report.clusterBytes,
        "total_clusters": report.totalClusters,
        "used_clusters": report.usedClusters,
        "free_clusters": report.freeClusters,
        "used_bytes": report.usedBytes,
        "free_bytes": report.freeBytes,
        "used_extents": report.usedExtents,
        "mft_bytes": report.mftBytes,
        "eta_basis": report.etaBasis,
    ]
    scope["eta_low_seconds"] = report.etaLowSeconds.map { $0 as Any } ?? NSNull()
    scope["eta_high_seconds"] = report.etaHighSeconds.map { $0 as Any } ?? NSNull()

    var object: [String: Any] = [
        "status": "scope-report-complete",
        "image": image,
        "mapfile": mapfile,
        "sidecar": sidecar,
        "partial": report.limitBytes != nil,
        "scope_report": scope,
    ]
    if let limit = report.limitBytes {
        object["limit_bytes"] = limit
        object["used_bytes_inside_limit"] = report.usedBytesInsideLimit.map { $0 as Any } ?? NSNull()
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let text = String(data: data, encoding: .utf8) else {
        return "{}\n"
    }
    return text + "\n"
}

// MARK: - Formatting

private func scopeField(_ label: String, _ value: String) -> String {
    let width = 10
    return label.count >= width
        ? label + " " + value
        : label + String(repeating: " ", count: width - label.count) + value
}

private func scopeBytes(_ value: Int64) -> String {
    if value >= 1_048_576 {
        return String(format: "%lld bytes (%.1f MiB)", value, Double(value) / 1_048_576)
    }
    if value >= 1_024 {
        return String(format: "%lld bytes (%.1f KiB)", value, Double(value) / 1_024)
    }
    return "\(value) bytes"
}

private func scopeDurationRange(low: Double, high: Double) -> String {
    if high < 10 {
        return String(format: "~%.1f–%.1f s", low, high)
    }
    if high < 60 {
        return String(format: "~%.0f–%.0f s", low, high)
    }
    if high < 3_600 {
        return String(format: "~%.0f–%.0f min", low / 60, high / 60)
    }
    return String(format: "~%.1f–%.1f h", low / 3_600, high / 3_600)
}
