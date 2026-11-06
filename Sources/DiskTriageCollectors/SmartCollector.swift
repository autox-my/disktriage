import Foundation
import DiskTriageCore

/// SMART health for one whole disk plus the status it was collected with.
public struct SmartCollection: Sendable, Equatable {
    public let status: SignalStatus
    public let signals: SmartSignals
    public let reason: String?

    public init(status: SignalStatus, signals: SmartSignals? = nil, reason: String? = nil) {
        self.status = status
        self.signals = signals ?? SmartSignals(status: status)
        self.reason = reason
    }
}

/// Reads SMART with `smartctl --json=o -a /dev/diskN`.
///
/// Measured on macOS 27.2 (P0 phase B/C): every device type fails over USB mass
/// storage with "Not a device of type 'scsi'" or "Operation not supported by
/// device". Those are `unsupported` with the recorded reason, not errors and
/// never a zero counter set. A success is `ok` only when a real ATA attribute
/// table parses; NVMe output has none and is `unsupported` for this HDD tool.
public struct SmartCollector: Sendable {
    private let executor: any CommandExecuting

    public init(executor: any CommandExecuting = ProcessRunner()) {
        self.executor = executor
    }

    public func collect(bsd: String) -> SmartCollection {
        let node = "/dev/\(bsd)"
        let result = executor.run(.smartctl(query: .all, node: node))

        switch result.outcome {
        case .timeout:
            return SmartCollection(
                status: .timeout,
                reason: "smartctl -a \(node) did not answer within \(result.durationMs) ms"
            )
        case .denied:
            return SmartCollection(status: .denied, reason: "smartctl -a \(node) was denied")
        case .notFound:
            return SmartCollection(status: .error, reason: "smartctl was not found")
        case .policyRejected:
            return SmartCollection(status: .error, reason: "smartctl -a \(node) is not allow-listed")
        case .ok, .error:
            return parse(result, node: node)
        }
    }

    private func parse(_ result: CollectorResult, node: String) -> SmartCollection {
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return SmartCollection(
                status: .error,
                reason: "smartctl -a \(node) exited \(result.exitCode.map(String.init) ?? "on a signal") without JSON"
            )
        }

        let smartctl = object["smartctl"] as? [String: Any] ?? [:]
        let messages = smartctlMessages(smartctl, stderr: result.stderr)

        // The measured USB-bridge failures. The message is the evidence, so it
        // is kept verbatim as the section's reason.
        if let unsupported = messages.first(where: Self.isUnsupportedMessage) {
            return SmartCollection(status: .unsupported, reason: unsupported)
        }

        if result.outcome == .error {
            return SmartCollection(
                status: .error,
                reason: "smartctl -a \(node) exited \(result.exitCode.map(String.init) ?? "on a signal")"
            )
        }

        if let inner = integer(smartctl["exit_status"]), inner != 0 {
            return SmartCollection(
                status: .error,
                reason: "smartctl reported exit_status \(inner) for \(node)"
            )
        }

        guard let attributes = object["ata_smart_attributes"] as? [String: Any],
              let table = attributes["table"] as? [[String: Any]],
              !table.isEmpty
        else {
            return SmartCollection(
                status: .unsupported,
                reason: "smartctl returned no ATA attribute table for \(node); media type or bridge hides it"
            )
        }

        var byID: [Int: [String: Any]] = [:]
        for attribute in table {
            if let id = integer(attribute["id"]) {
                byID[id] = attribute
            }
        }

        let smartStatus = object["smart_status"] as? [String: Any]
        let overall: String?
        switch smartStatus?["passed"] as? Bool {
        case .some(true): overall = "PASSED"
        case .some(false): overall = "FAILED"
        case .none: overall = nil
        }

        let selfTest = (object["ata_smart_data"] as? [String: Any])
            .flatMap { $0["self_test"] as? [String: Any] }
            .flatMap { $0["status"] as? [String: Any] }
            .flatMap { $0["string"] as? String }

        return SmartCollection(
            status: .ok,
            signals: SmartSignals(
                status: .ok,
                overall: overall,
                pending: rawValue(byID[197]),
                reallocated: rawValue(byID[5]),
                uncorrectable: rawValue(byID[198]),
                powerOnHours: rawValue(byID[9]),
                rawReadErrors: rawValue(byID[1]),
                errorLog: nil,
                selfTest: selfTest.map { SmartSelfTest(last: $0, ageHours: nil) },
                history: nil
            )
        )
    }

    private static func isUnsupportedMessage(_ message: String) -> Bool {
        message.contains("Not a device of type")
            || message.contains("Operation not supported by device")
            || message.contains("Operation not supported")
    }

    private func smartctlMessages(_ smartctl: [String: Any], stderr: String) -> [String] {
        var messages: [String] = []
        if let list = smartctl["messages"] as? [[String: Any]] {
            messages += list.compactMap { $0["string"] as? String }
        }
        if let output = smartctl["output"] as? [String] {
            messages += output
        }
        if !stderr.isEmpty {
            messages.append(stderr)
        }
        return messages
    }
}

private func rawValue(_ attribute: [String: Any]?) -> Int? {
    guard let raw = attribute?["raw"] as? [String: Any] else { return nil }
    return integer(raw["value"])
}

private func integer(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}
