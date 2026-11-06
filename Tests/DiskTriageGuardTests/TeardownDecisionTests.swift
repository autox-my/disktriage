import Foundation
import Testing
import DiskTriageGuard

/// The bench teardown rule (captures/p0-phase-c.sh, docs/p0-runbook.md phase C):
/// resume diskarbitrationd only if no new raw disk node appeared while it was
/// suspended; a node that is still present means the disk is attached, and
/// resuming would let macOS probe it.
struct TeardownDecisionTests {

    @Test("resume only when the node set did not grow")
    func resumesWhenNoNewNodeAppeared() {
        let start: Set<String> = ["rdisk0", "rdisk0s1", "rdisk3", "rdisk3s1"]
        #expect(teardownDecision(nodesAtStart: start, nodesNow: start) == .resume)
    }

    @Test("a shrunken node set resumes: the disk went away")
    func resumesWhenANodeDisappeared() {
        let start: Set<String> = ["rdisk0", "rdisk8", "rdisk8s1"]
        let now: Set<String> = ["rdisk0"]
        #expect(teardownDecision(nodesAtStart: start, nodesNow: now) == .resume)
    }

    @Test("a new node holds the daemon suspended and names the node")
    func holdsWhenTheNodeSetGrew() {
        let start: Set<String> = ["rdisk0", "rdisk0s1"]
        let now: Set<String> = ["rdisk0", "rdisk0s1", "rdisk8", "rdisk8s1"]
        #expect(
            teardownDecision(nodesAtStart: start, nodesNow: now)
                == .hold(newNodes: ["rdisk8", "rdisk8s1"])
        )
    }

    @Test("a replaced node holds: the count is equal but a new disk is attached")
    func holdsWhenANodeWasReplaced() {
        let start: Set<String> = ["rdisk0", "rdisk7"]
        let now: Set<String> = ["rdisk0", "rdisk8"]
        #expect(teardownDecision(nodesAtStart: start, nodesNow: now) == .hold(newNodes: ["rdisk8"]))
    }
}

struct RawDiskNodeTests {

    @Test("node names normalise from an ls capture, partitions included")
    func readsTheRecordedNavigationCapture() {
        // Real lines from captures/a2.txt (Phase A baseline), redacted nothing:
        // device nodes carry no serial.
        let listing = [
            "crw-r-----  1 root  operator  0x1000000 Nov  6 20:28 /dev/rdisk0",
            "crw-r-----  1 root  operator  0x1000003 Nov  6 20:28 /dev/rdisk0s2",
            "cr--r-----  1 root  operator  0x1000013 Nov  6 20:28 /dev/rdisk3s1s1",
            "rdisk8",
            "not-a-disk",
            "/dev/disk9",
        ]
        #expect(
            rawDiskNodeNames(from: listing)
                == ["rdisk0", "rdisk0s2", "rdisk3s1s1", "rdisk8"]
        )
    }

    @Test("only rdiskN and its partitions are raw disk nodes")
    func ignoresNamesThatAreNotRawDiskNodes() {
        #expect(rawDiskNodeNames(from: ["rdisk", "rdisk0s", "disk0", "rdiskx"]) == [])
    }
}
