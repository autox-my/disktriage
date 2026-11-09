import Foundation
import Darwin

/// One directory listing's outcome. Names are all the probe needs: a network
/// mount can answer `readdir` instantly while any attribute lookup on it never
/// returns, so the lister must not stat or resolve an entry.
public enum VolumeListingResult: Equatable, Sendable {
    case names([String])
    case failed(String)
}

/// The seam the removable-volume probe reads `/Volumes` through. Injected in
/// tests; the shipped implementation is `POSIXVolumeLister`.
public protocol VolumeListing: Sendable {
    func entryNames(atPath path: String) -> VolumeListingResult
}

/// Lists directory entries with `opendir`/`readdir` and nothing else.
///
/// `FileManager.contentsOfDirectory` resolves entry metadata, which blocks on a
/// hung network mount (`stat /Volumes/<mount>` never returns). `ls -f` and
/// `readdir` return the same names without touching the mount.
public struct POSIXVolumeLister: VolumeListing {
    public init() {}

    public func entryNames(atPath path: String) -> VolumeListingResult {
        guard let directory = opendir(path) else {
            return .failed(String(cString: strerror(errno)))
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let end = raw.firstIndex(of: 0) ?? raw.endIndex
                return String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return .names(names)
    }
}

/// A listing that either completed or ran past its hard bound.
enum BoundedVolumeListing: Equatable, Sendable {
    case listed(VolumeListingResult)
    case timedOut
}

/// Runs `lister` on a worker thread and stops waiting at `timeout`.
///
/// The worker is abandoned, not joined: a `readdir` stuck in the kernel cannot
/// be cancelled, and the self-test must return regardless. A hung mount is
/// evidence (a timeout), never a pass.
func boundedVolumeListing(
    using lister: any VolumeListing,
    path: String,
    within timeout: TimeInterval
) -> BoundedVolumeListing {
    let box = ListingBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.store(lister.entryNames(atPath: path))
        finished.signal()
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        return .timedOut
    }
    guard let result = box.value else { return .timedOut }
    return .listed(result)
}

/// `DispatchQueue.async` needs Sendable storage; the lock makes the worker's
/// result safe to read after the semaphore establishes the ordering.
private final class ListingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VolumeListingResult?

    func store(_ result: VolumeListingResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: VolumeListingResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
