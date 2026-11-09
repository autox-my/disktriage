import Foundation
import Testing
import DiskTriageTestSupport
import DiskTriageCore
@testable import DiskTriageCollectors

/// A hung network mount in `/Volumes` makes any per-entry attribute lookup
/// block forever. The probe lists names only, and even that call is bounded:
/// these tests inject the lister and the bound so no hang is ever observed.
struct VolumeListingTests {
    // REQ-0321: `ls -f /Volumes` is instant beside a hung WebDAV mount while
    // `stat` on the mount never returns. The lister must therefore return
    // names from readdir and never resolve the entries.
    @Test("REQ0321 the volume lister returns entry names without resolving them")
    func REQ0321_listsEntryNamesWithoutResolvingThem() throws {
        let temp = TempDir()
        try FileManager.default.createDirectory(
            atPath: temp.child("volume-a"),
            withIntermediateDirectories: true
        )
        // A dangling symlink and a FIFO both exist as directory entries while
        // an attribute lookup on them is not the plain name readdir returns.
        try FileManager.default.createSymbolicLink(
            atPath: temp.child("dangling"),
            withDestinationPath: temp.child("missing-target")
        )
        let fifo = temp.child("pipe")
        #expect(mkfifo(fifo, 0o600) == 0, "the fixture is a real FIFO")

        let outcome = POSIXVolumeLister().entryNames(atPath: temp.path)

        let names: [String]
        switch outcome {
        case .names(let listed): names = listed
        case .failed(let reason): Issue.record("expected names, got failure: \(reason)"); return
        }
        #expect(Set(names) == ["volume-a", "dangling", "pipe"], "names only: \(names)")
        #expect(!names.contains("."), "the current-directory entry is not a volume")
        #expect(!names.contains(".."), "the parent entry is not a volume")
    }

    @Test("REQ0321 an unreadable directory is a failure, not an empty list")
    func REQ0321_unreadableDirectoryIsNotAnEmptyList() {
        let outcome = POSIXVolumeLister().entryNames(atPath: "/nonexistent-disktriage-volume-list")

        switch outcome {
        case .failed: break
        case .names(let names): Issue.record("an absent directory listed \(names)")
        }
    }

    // REQ-0322: a lister that blocks past the bound is a timeout. A timeout is
    // not a measurement, so the row is UNVERIFIABLE and never PASS.
    @Test("REQ0322 a blocked listing is a timeout, never a pass")
    func REQ0322_blockedListingTimesOutWithoutPassing() {
        let lister = BlockingVolumeLister()
        let probes = LiveCheckProbes(
            environment: [:],
            volumeLister: lister,
            volumeListTimeout: 0.2
        )

        let started = Date()
        let probe = probes.removableVolumeAccess()
        let elapsed = Date().timeIntervalSince(started)

        #expect(lister.callCount == 1, "the probe asked the lister once")
        #expect(probe.status == .unverifiable, "a timeout is not a measurement")
        #expect(probe.detail.contains("/Volumes"), "the row names what did not answer")
        #expect(probe.detail.contains("did not answer"), "the reason is a timeout: \(probe.detail)")
        #expect(elapsed < 2, "the probe returned within its bound; took \(elapsed) s")
    }
}

/// Blocks as a stat on a hung mount does, but releases itself after a few
/// seconds so a broken bound fails the test instead of hanging the suite.
private final class BlockingVolumeLister: VolumeListing, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func entryNames(atPath path: String) -> VolumeListingResult {
        lock.lock()
        calls += 1
        lock.unlock()
        started.signal()
        _ = release.wait(timeout: .now() + 5)
        return .names(["would-never-be-reached-in-time"])
    }
}
