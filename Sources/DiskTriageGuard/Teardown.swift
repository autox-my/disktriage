import Foundation

/// What teardown does to diskarbitrationd after a suspended session.
public enum GuardTeardown: Equatable, Sendable {
    /// No new raw disk node appeared: it is safe to send SIGCONT.
    case resume
    /// A new raw disk node is still present (the disk is attached). Stay
    /// suspended and tell the operator to unplug, then resume by hand.
    case hold(newNodes: [String])
}

/// The bench rule from captures/p0-phase-c.sh: resume only when the node list
/// has no entry that was not there at start. A shrunken list is safe (the disk
/// is gone); a replacement with the same count is not — compare sets, not sizes.
public func teardownDecision(nodesAtStart: Set<String>, nodesNow: Set<String>) -> GuardTeardown {
    let appeared = nodesNow.subtracting(nodesAtStart)
    guard appeared.isEmpty else {
        return .hold(newNodes: appeared.sorted())
    }
    return .resume
}

/// A provider of the current raw whole-disk and partition node names
/// ("rdisk8", "rdisk8s1") from /dev.
public protocol RawDiskNodeProviding: Sendable {
    func rawDiskNodes() -> Set<String>
}

/// The live provider: the same set the P0 script captured with
/// `ls /dev/rdisk*`. A failed listing is an empty set, and an empty set never
/// hides a new node by itself — the caller compares it with the start set.
public struct LiveRawDiskNodes: RawDiskNodeProviding {
    public init() {}

    public func rawDiskNodes() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return rawDiskNodeNames(from: names)
    }
}

/// Parses `ls /dev/rdisk*`-shaped lines (or bare names) into node names.
public func rawDiskNodeNames(from listing: [String]) -> Set<String> {
    var names: Set<String> = []
    for line in listing {
        let name = (line as NSString).lastPathComponent
        if isRawDiskNodeName(name) {
            names.insert(name)
        }
    }
    return names
}

/// `rdisk<digits>` optionally followed by `s<digits>` partition suffixes.
func isRawDiskNodeName(_ name: String) -> Bool {
    guard name.hasPrefix("rdisk") else { return false }
    let rest = name.dropFirst("rdisk".count)
    guard !rest.isEmpty else { return false }
    var expectingDigits = true
    for character in rest {
        if character.isNumber {
            expectingDigits = false
        } else if character == "s" && !expectingDigits {
            expectingDigits = true
        } else {
            return false
        }
    }
    return !expectingDigits
}
