import Foundation
@testable import DiskTriageCollectors

/// A scripted process layer: the tests supply recorded `CollectorResult`
/// values, so the whole collector pipeline runs with no subprocess and no
/// hardware. It records every command it was asked for.
final class RecordingExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [String: CollectorResult]
    private var recorded: [TriageCommand] = []
    private var recordedTimeouts: [TimeInterval] = []

    init(_ results: [TriageCommand: CollectorResult]) {
        self.results = Dictionary(uniqueKeysWithValues: results.map { (key, value) in
            (RecordingExecutor.key(key), value)
        })
    }

    var commands: [TriageCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The per-command timeouts a collector asked for, in call order.
    var requestedTimeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTimeouts
    }

    func run(_ command: TriageCommand) -> CollectorResult {
        lock.lock()
        recorded.append(command)
        lock.unlock()
        return results[RecordingExecutor.key(command)] ?? .ok("")
    }

    func run(_ command: TriageCommand, timeout: TimeInterval) -> CollectorResult {
        lock.lock()
        recorded.append(command)
        recordedTimeouts.append(timeout)
        lock.unlock()
        return results[RecordingExecutor.key(command)] ?? .ok("")
    }

    private static func key(_ command: TriageCommand) -> String {
        if case .logShow = command {
            // The log collector varies `--last`; tests that need the exact
            // argv inspect `commands` instead.
            return "log"
        }
        return String(describing: command)
    }
}

func collectorFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DiskTriageCollectorsTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
