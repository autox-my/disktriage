import Foundation

/// One IOMedia node from `ioreg -r -c IOMedia -w 0`.
///
/// The tree preserves the parent chain, which is what makes an APFS volume
/// resolvable to its physical store: the synthesized container (`disk3`) is a
/// child of the store partition (`disk0s2`), which is a child of the physical
/// whole disk (`disk0`). Nothing here is inferred from a name.
public struct IORegMediaNode: Equatable, Sendable {
    public let className: String
    public let name: String?
    public let bsdName: String?
    public let whole: Bool?
    public let sizeBytes: Int64?
    public let uuid: String?

    public init(
        className: String,
        name: String? = nil,
        bsdName: String? = nil,
        whole: Bool? = nil,
        sizeBytes: Int64? = nil,
        uuid: String? = nil
    ) {
        self.className = className
        self.name = name
        self.bsdName = bsdName
        self.whole = whole
        self.sizeBytes = sizeBytes
        self.uuid = uuid
    }

    /// The synthesized whole disk an APFS container publishes. `IOMedia` (a
    /// partition or a physical whole disk) is not this class.
    public var isAPFSContainerMedia: Bool {
        className == "AppleAPFSMedia"
    }
}

/// The answer the destination rule needs. An unknown backing disk is a
/// finding, never a pass: `image` refuses to write an image to a volume it
/// cannot prove is off the source disk.
public enum BackingDiskResolution: Equatable, Sendable {
    case wholeDisks([String])
    case unknown(String)
}

/// The parsed io registry media tree. `parents[index]` is the nearest
/// enclosing node, from the `+-o` indent depth.
public struct IORegMediaTree: Equatable, Sendable {
    public let nodes: [IORegMediaNode]
    public let parents: [Int?]

    public init(nodes: [IORegMediaNode], parents: [Int?]) {
        self.nodes = nodes
        self.parents = parents
    }

    /// Parses `ioreg -r -c IOMedia -w 0`. `nil` when there is no media node at
    /// all, which is not a tree with zero disks.
    public static func parse(_ text: String) -> IORegMediaTree? {
        var nodes: [IORegMediaNode] = []
        var parents: [Int?] = []
        var stack: [(depth: Int, index: Int)] = []
        var currentIndex: Int?

        func appendNode(_ line: String) {
            guard let header = mediaHeader(line) else { return }
            while let last = stack.last, last.depth >= header.depth {
                stack.removeLast()
            }
            let index = nodes.count
            nodes.append(IORegMediaNode(
                className: header.className,
                name: header.name,
                bsdName: nil,
                whole: nil,
                sizeBytes: nil,
                uuid: nil
            ))
            parents.append(stack.last?.index)
            stack.append((header.depth, index))
            currentIndex = index
        }

        func appendProperty(_ line: String) {
            guard let index = currentIndex else { return }
            let node = nodes[index]
            nodes[index] = IORegMediaNode(
                className: node.className,
                name: node.name,
                bsdName: node.bsdName ?? mediaString("BSD Name", in: line),
                whole: node.whole ?? mediaBoolean("Whole", in: line),
                sizeBytes: node.sizeBytes ?? mediaInteger("Size", in: line),
                uuid: node.uuid ?? mediaString("UUID", in: line)
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.contains("+-o ") {
                appendNode(line)
            } else {
                appendProperty(line)
            }
        }

        guard !nodes.isEmpty else { return nil }
        return IORegMediaTree(nodes: nodes, parents: parents)
    }

    /// The physical whole disks behind a mounted whole disk.
    ///
    /// A physical whole disk is its own backing. A synthesized APFS container
    /// is walked to every physical store branch publishing the same container
    /// UUID, so a multi-store container names all of them.
    public func backingWholeDisks(forMountedWholeDisk wholeDisk: String) -> BackingDiskResolution {
        let matches = nodes.indices.filter { nodes[$0].bsdName == wholeDisk }
        guard !matches.isEmpty else {
            return .unknown("ioreg has no IOMedia for \(wholeDisk)")
        }

        var disks: [String] = []
        for match in matches {
            if let container = firstAPFSAncestor(of: match) {
                let identity = container.uuid ?? container.bsdName
                let stores = nodes.indices.filter { index in
                    let node = nodes[index]
                    guard node.isAPFSContainerMedia else { return false }
                    guard let identity else { return index == match }
                    return node.uuid == identity || node.bsdName == container.bsdName
                }
                guard !stores.isEmpty else {
                    return .unknown("the APFS container for \(wholeDisk) has no physical store in ioreg")
                }
                for store in stores {
                    guard let physical = nearestPhysicalWholeAncestor(of: store) else {
                        return .unknown(
                            "the APFS store for \(wholeDisk) has no physical whole disk in ioreg"
                        )
                    }
                    append(physical, to: &disks)
                }
            } else {
                guard let physical = nearestPhysicalWholeAncestor(of: match) else {
                    return .unknown("ioreg has no physical whole disk above \(wholeDisk)")
                }
                append(physical, to: &disks)
            }
        }

        guard !disks.isEmpty else {
            return .unknown("ioreg has no physical whole disk above \(wholeDisk)")
        }
        return .wholeDisks(disks)
    }

    private func append(_ value: String, to values: inout [String]) {
        if !values.contains(value) { values.append(value) }
    }

    private func nearestPhysicalWholeAncestor(of index: Int) -> String? {
        var cursor: Int? = index
        while let current = cursor {
            let node = nodes[current]
            if node.whole == true, !node.isAPFSContainerMedia, let bsd = node.bsdName {
                return bsd
            }
            cursor = parents[current]
        }
        return nil
    }

    private func firstAPFSAncestor(of index: Int) -> IORegMediaNode? {
        var cursor: Int? = index
        while let current = cursor {
            if nodes[current].isAPFSContainerMedia {
                return nodes[current]
            }
            cursor = parents[current]
        }
        return nil
    }
}

/// The mount source `statfs` reports, resolved to a local whole-disk name.
/// A network share or any non-`/dev/disk` source is not a local disk.
public enum MountedDeviceSource {
    public static func wholeDiskName(fromMountSource source: String) -> String? {
        guard source.hasPrefix("/dev/") else { return nil }
        var name = (source as NSString).lastPathComponent
        if name.hasPrefix("r") { name.removeFirst() }
        guard name.hasPrefix("disk") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return "disk" + digits
    }
}

/// Ties the `statfs` source to the io registry tree.
public enum BackingDiskResolver {
    public static func resolve(mountSource: String, tree: IORegMediaTree) -> BackingDiskResolution {
        guard let whole = MountedDeviceSource.wholeDiskName(fromMountSource: mountSource) else {
            return .unknown("the mount source \(mountSource) is not a local /dev/disk node")
        }
        return tree.backingWholeDisks(forMountedWholeDisk: whole)
    }
}

// MARK: - Header and property parsing

private func mediaHeader(_ line: String) -> (depth: Int, className: String, name: String?)? {
    guard let range = line.range(of: "+-o ") else { return nil }
    let prefix = line[line.startIndex..<range.lowerBound]
    guard prefix.allSatisfy({ $0 == " " || $0 == "|" }) else { return nil }
    let depth = line.distance(from: line.startIndex, to: range.lowerBound)
    let rest = String(line[range.upperBound...])
    guard let className = mediaFirstGroup(#"<class ([^,>]+)"#, in: rest) else { return nil }
    let name = rest
        .split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map { $0.trimmingCharacters(in: .whitespaces) }
    return (depth, className, name?.isEmpty == false ? name : nil)
}

private func mediaString(_ key: String, in text: String) -> String? {
    mediaFirstGroup("\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*\"([^\"]*)\"", in: text)
}

private func mediaInteger(_ key: String, in text: String) -> Int64? {
    mediaFirstGroup("\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*([0-9]+)", in: text)
        .flatMap(Int64.init)
}

private func mediaBoolean(_ key: String, in text: String) -> Bool? {
    guard let value = mediaFirstGroup(
        "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*(Yes|No)",
        in: text
    ) else { return nil }
    return value == "Yes"
}

private func mediaFirstGroup(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}
