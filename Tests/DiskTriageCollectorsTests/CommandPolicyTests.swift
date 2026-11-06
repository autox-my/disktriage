import Testing
import DiskTriageCollectors

/// The fixed read-only allow-list from diskdoctor.md §2.7: policy is checked
/// before `exec`, and anything not named here is rejected.
struct CommandPolicyTests {
    private let policy = CommandPolicy.triage

    @Test("the allow-listed read-only shapes are accepted")
    func acceptsTheFixedReadOnlyShapes() {
        let allowed: [[String]] = [
            ["/usr/sbin/diskutil", "list", "-plist"],
            ["/usr/sbin/diskutil", "info", "-plist", "disk0"],
            ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDriver", "-k", "Statistics"],
            ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDriver", "-k", "Statistics", "-d", "1", "-w", "0"],
            ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDriver", "-w", "0"],
            ["/usr/sbin/ioreg", "-r", "-c", "IOMedia", "-d", "1", "-w", "0"],
            ["/usr/bin/log", "show", "--last", "1m", "--predicate", #"eventMessage CONTAINS "medium error""#],
            ["/usr/bin/log", "show", "--last", "6h", "--style", "ndjson", "--predicate", #"eventMessage CONTAINS "medium error""#],
            ["/usr/bin/log", "show", "--last", "72h"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-i", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-H", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-A", "/dev/rdisk4"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-a", "/dev/disk4"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-d", "sat", "-a", "/dev/disk4"],
            ["/usr/local/bin/smartctl", "--json=o", "-d", "auto", "-i", "/dev/disk4"],
        ]
        for argv in allowed {
            #expect(policy.evaluate(argv) == .allowed, "expected allowed: \(argv)")
        }
    }

    // REQ-0013: a fixed allow-list of read-only commands.
    @Test("anything outside the allow-list is rejected")
    func REQ0013_rejectsAnythingNotOnTheAllowList() {
        let rejected: [[String]] = [
            [],
            ["/bin/rm", "-rf", "/"],
            ["/bin/sh", "-c", "echo hi"],
            ["/usr/bin/env"],
            ["/usr/bin/touch", "/tmp/x"],
            ["/usr/sbin/diskutil", "list"],
            ["/usr/sbin/diskutil", "info", "disk0"],
            ["/usr/sbin/diskutil", "info", "-plist", "disk0s1"],
            ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDriver"],
            ["/usr/bin/log", "show", "--predicate", "x"],
            ["/usr/bin/log", "stream", "--last", "1m"],
            ["/usr/bin/log", "show", "--last", "1m", "--extra"],
            ["/opt/homebrew/bin/smartctl", "-i", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-i", "/dev/disk0", "extra"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-i", "/dev/disk0s1"],
        ]
        for argv in rejected {
            #expect(policy.evaluate(argv) != .allowed, "expected rejected: \(argv)")
        }
    }

    // REQ-0014: triage never starts a SMART self-test.
    @Test("every SMART self-test and write flag is rejected before exec")
    func REQ0014_rejectsEverySelfTestAndWriteFlag() {
        let selfTests: [[String]] = [
            ["/opt/homebrew/bin/smartctl", "-t", "short", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-t", "long", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--test=short", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "-X", "/dev/disk0"],
        ]
        for argv in selfTests {
            #expect(policy.evaluate(argv) == .rejected(.smartctlSelfTest), "\(argv)")
        }

        let writes: [[String]] = [
            ["/opt/homebrew/bin/smartctl", "-s", "on", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "-s", "off", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "-S", "on", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "-o", "on", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "-o", "off", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--set", "standby,5", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "-T", "verypermissive", "/dev/disk0"],
        ]
        for argv in writes {
            #expect(policy.evaluate(argv) == .rejected(.smartctlWriteFlag), "\(argv)")
        }

        let deviceTypes: [[String]] = [
            ["/opt/homebrew/bin/smartctl", "--json=o", "-d", "scsi", "-a", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-d", "nvme", "-a", "/dev/disk0"],
            ["/opt/homebrew/bin/smartctl", "--json=o", "-d", "sat,12", "-a", "/dev/disk0"],
        ]
        for argv in deviceTypes {
            #expect(policy.evaluate(argv) == .rejected(.smartctlDeviceType), "\(argv)")
        }
    }
}
