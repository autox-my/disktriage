import Foundation
import Testing
import DiskTriageCore
import DiskTriageCollectors

/// SMART over USB is unreachable on this build (P0 phase B/C). Every failure
/// must keep its own status, and only a real ATA attribute table is `ok`.
struct SmartCollectorTests {

    @Test("the Phase B 'Not a device of type scsi' recording is unsupported with its reason")
    func notADeviceOfTypeScsiIsUnsupported() throws {
        let collection = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk8"): CollectorResult(
                outcome: .error,
                exitCode: 1,
                stdout: try collectorFixture("smart-unsupported-not-scsi.json")
            ),
        ])).collect(bsd: "disk8")

        #expect(collection.status == .unsupported, "not a permission or tool failure")
        #expect(collection.signals.pending == nil, "no counters")
        let reason = try #require(collection.reason, "reason")
        #expect(reason.contains("Not a device of type 'scsi'"), "the recorded smartctl text: \(reason)")
    }

    @Test("the Phase B 'Operation not supported by device' recording is unsupported")
    func operationNotSupportedIsUnsupported() throws {
        let collection = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk8"): CollectorResult(
                outcome: .error,
                exitCode: 2,
                stdout: try collectorFixture("smart-unsupported-operation-not-supported.json")
            ),
        ])).collect(bsd: "disk8")

        #expect(collection.status == .unsupported, "status")
        #expect(collection.reason?.contains("Operation not supported by device") == true,
                "the recorded text: \(collection.reason ?? "nil")")
    }

    @Test("the Phase C MiNaH recording is unsupported too")
    func phaseCIsUnsupported() throws {
        let collection = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk8"): CollectorResult(
                outcome: .error,
                exitCode: 1,
                stdout: try collectorFixture("smart-unsupported-phase-c.json")
            ),
        ])).collect(bsd: "disk8")

        #expect(collection.status == .unsupported, "status")
        #expect(collection.signals.pending == nil, "no counters")
    }

    @Test("a timeout is timeout and a denial is denied")
    func timeoutAndDenialKeepTheirStatuses() {
        let timeout = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk8"): .timeout(),
        ])).collect(bsd: "disk8")
        #expect(timeout.status == .timeout, "timeout")
        #expect(timeout.signals.pending == nil, "no counters")

        let denied = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk8"): .denied("EPERM"),
        ])).collect(bsd: "disk8")
        #expect(denied.status == .denied, "denied")
    }

    @Test("a nonzero exit without a known unsupported message is an error")
    func aNonzeroExitIsAnError() {
        let collection = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk8"): CollectorResult(
                outcome: .error, exitCode: 9, stdout: #"{"smartctl":{"exit_status":0}}"#
            ),
        ])).collect(bsd: "disk8")

        #expect(collection.status == .error, "status")
        #expect(collection.signals.pending == nil, "no counters")
    }

    @Test("a successful JSON with no ATA attribute table is unsupported, not ok")
    func noAttributesIsUnsupported() {
        let collection = SmartCollector(executor: RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk0"): .ok(#"{"smartctl":{"exit_status":0}}"#),
        ])).collect(bsd: "disk0")

        #expect(collection.status == .unsupported, "no attribute table means no measurement")
        #expect(collection.signals.pending == nil, "no counters")
    }

    @Test("SYNTHETIC ATA attribute table: the plan's counters parse and only then is SMART ok")
    func syntheticATATableParsesTheCounters() throws {
        let executor = RecordingExecutor([
            .smartctl(query: .all, node: "/dev/disk4"): .ok(try collectorFixture("smart-ata-synthetic.json")),
        ])
        let collection = SmartCollector(executor: executor).collect(bsd: "disk4")

        #expect(collection.status == .ok, "a real attribute table is the only success")
        #expect(collection.signals.overall == "PASSED", "overall")
        #expect(collection.signals.pending == 131, "Current_Pending_Sector")
        #expect(collection.signals.reallocated == 14, "Reallocated_Sector_Ct")
        #expect(collection.signals.uncorrectable == 0, "Offline_Uncorrectable")
        #expect(collection.signals.powerOnHours == 4_531, "Power_On_Hours")
        #expect(collection.signals.rawReadErrors == 21_545, "Raw_Read_Error_Rate")
        #expect(collection.signals.history == nil, "first sight: no invented history")
        #expect(executor.commands == [.smartctl(query: .all, node: "/dev/disk4")],
                "the plan's fast query on the block node, never a raw device")
    }
}
