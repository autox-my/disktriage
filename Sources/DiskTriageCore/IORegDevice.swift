import Foundation

/// The whole-disk identity an `IOBlockStorageDevice` subtree exposes without
/// DiskArbitration (diskdoctor.md §4). This is the path that keeps working
/// while diskarbitrationd is suspended, when `diskutil` hangs system-wide
/// (P0 phase C).
///
/// Every field is optional when the recording does not expose it: an absent
/// serial stays `nil`, never an empty string or a zero.
public struct IORegDeviceIdentity: Sendable, Equatable {
    public let bsd: String
    public let sizeBytes: Int64?
    public let blockSize: Int64?
    public let model: String?
    public let vendor: String?
    public let serial: String?
    /// `usb`, `nvme`, `sata`, … after the shared interconnect mapping.
    public let bus: String?
    /// `hdd`, `ssd`, or `nil` when `Medium Type` is absent.
    public let media: String?
    public let removable: Bool?
    public let ejectable: Bool?
    public let internalDisk: Bool?
    public let whole: Bool?

    public init(
        bsd: String,
        sizeBytes: Int64? = nil,
        blockSize: Int64? = nil,
        model: String? = nil,
        vendor: String? = nil,
        serial: String? = nil,
        bus: String? = nil,
        media: String? = nil,
        removable: Bool? = nil,
        ejectable: Bool? = nil,
        internalDisk: Bool? = nil,
        whole: Bool? = nil
    ) {
        self.bsd = bsd
        self.sizeBytes = sizeBytes
        self.blockSize = blockSize
        self.model = model
        self.vendor = vendor
        self.serial = serial
        self.bus = bus
        self.media = media
        self.removable = removable
        self.ejectable = ejectable
        self.internalDisk = internalDisk
        self.whole = whole
    }
}

/// Parses the text of `ioreg -r -c IOBlockStorageDevice -w 0 -l` (or the USB
/// host device tree, which nests the same nodes) into one whole disk.
///
/// Pure string to value: no process runs here and nothing is guessed. The
/// target is a whole-disk `IOMedia` whose `BSD Name` equals `bsd`; the identity
/// comes from the enclosing `IOBlockStorageDevice`'s `Device Characteristics`
/// and `Protocol Characteristics`, with the USB host device's serial string as
/// the last resort.
public enum IORegDeviceParser {
    public static func parse(_ text: String, bsd: String) -> IORegDeviceIdentity? {
        let nodes = parseNodes(text)
        guard !nodes.isEmpty else { return nil }
        let parents = parentIndices(of: nodes)

        guard let mediaIndex = nodes.firstIndex(where: { node in
            node.className == "IOMedia"
                && dictionaryString("BSD Name", in: node.properties) == bsd
                && boolean("Whole", in: node.properties) == true
        }) else { return nil }

        let media = nodes[mediaIndex]
        let deviceIndex = ancestorChain(from: mediaIndex, parents: parents)
            .first { nodes[$0].properties.contains("\"Device Characteristics\"") }
        let deviceProperties = deviceIndex.map { nodes[$0].properties } ?? ""
        let characteristics = dictionary(
            "Device Characteristics",
            in: deviceProperties
        ) ?? ""
        let protocols = dictionary("Protocol Characteristics", in: deviceProperties) ?? ""

        let location = dictionaryString("Physical Interconnect Location", in: protocols)
        let internalDisk: Bool?
        switch location?.lowercased() {
        case "internal": internalDisk = true
        case "external": internalDisk = false
        default: internalDisk = nil
        }

        let interconnect = dictionaryString("Physical Interconnect", in: protocols)
        let bus = StorageBus.name(
            fromInterconnect: interconnect ?? inferredInterconnect(nodes: nodes, parents: parents, from: mediaIndex),
            isInternal: internalDisk
        )

        let model = nonEmpty(dictionaryString("Product Name", in: characteristics))
            ?? nonEmpty(dictionaryString("Product Name", in: deviceProperties))
            ?? mediaName(nodes[mediaIndex].header)
        let vendor = nonEmpty(dictionaryString("Vendor Name", in: characteristics))
            ?? nonEmpty(dictionaryString("Vendor Name", in: deviceProperties))
            ?? ancestorString("USB Vendor Name", from: mediaIndex, nodes: nodes, parents: parents)
        let serial = nonEmpty(dictionaryString("Serial Number", in: characteristics))
            ?? nonEmpty(dictionaryString("Serial Number", in: deviceProperties))
            ?? ancestorString("USB Serial Number", from: mediaIndex, nodes: nodes, parents: parents)
            ?? ancestorString("kUSBSerialNumberString", from: mediaIndex, nodes: nodes, parents: parents)

        return IORegDeviceIdentity(
            bsd: bsd,
            sizeBytes: integer("Size", in: media.properties),
            blockSize: integer("Preferred Block Size", in: media.properties),
            model: model,
            vendor: vendor,
            serial: serial.map(normalizedSerial),
            bus: bus,
            media: mediaType(dictionaryString("Medium Type", in: characteristics)
                ?? dictionaryString("Medium Type", in: deviceProperties)),
            removable: boolean("Removable", in: media.properties),
            ejectable: boolean("Ejectable", in: media.properties),
            internalDisk: internalDisk,
            whole: boolean("Whole", in: media.properties)
        )
    }
}

/// The interconnect mapping shared by the `diskutil` and `ioreg` identity
/// paths, so the two can never disagree about what `nvme` means.
public enum StorageBus {
    public static func name(fromInterconnect interconnect: String?, isInternal: Bool?) -> String? {
        guard let interconnect else { return nil }
        let lowered = interconnect.lowercased()
        if lowered == "apple fabric" && isInternal == true {
            return "nvme"
        }
        switch lowered {
        case "pci-express", "pci express":
            return "pcie"
        default:
            return lowered
        }
    }
}

/// `ps -o stat=` prints a T prefix for a stopped process ("T", "T+", "T<").
/// The guard's suspend check and the collector's "diskutil would hang" check
/// share this one rule.
public enum ProcessState {
    public static func isStopped(_ state: String?) -> Bool {
        state?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T") == true
    }
}

// MARK: - Node parsing

private struct IORegNode {
    let depth: Int
    let header: String
    let className: String
    var properties: String
}

private func parseNodes(_ text: String) -> [IORegNode] {
    var nodes: [IORegNode] = []
    var current: Int?

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if let header = nodeHeader(line) {
            nodes.append(header)
            current = nodes.count - 1
        } else if let current {
            nodes[current].properties += line + "\n"
        }
    }
    return nodes
}

private func nodeHeader(_ line: String) -> IORegNode? {
    guard let range = line.range(of: "+-o ") else { return nil }
    let prefix = line[line.startIndex..<range.lowerBound]
    guard prefix.allSatisfy({ $0 == " " || $0 == "|" }) else { return nil }
    let depth = line.distance(from: line.startIndex, to: range.lowerBound)
    let rest = String(line[range.upperBound...])
    let className = firstGroup(#"<class ([^,>]+)"#, in: rest) ?? ""
    return IORegNode(depth: depth, header: rest, className: className, properties: "")
}

private func parentIndices(of nodes: [IORegNode]) -> [Int?] {
    var parents = [Int?](repeating: nil, count: nodes.count)
    var stack: [Int] = []
    for index in nodes.indices {
        while let last = stack.last, nodes[last].depth >= nodes[index].depth {
            stack.removeLast()
        }
        parents[index] = stack.last
        stack.append(index)
    }
    return parents
}

/// The node itself followed by its ancestors, nearest first.
private func ancestorChain(from index: Int, parents: [Int?]) -> [Int] {
    var chain: [Int] = []
    var cursor: Int? = index
    while let current = cursor {
        chain.append(current)
        cursor = parents[current]
    }
    return chain
}

private func inferredInterconnect(nodes: [IORegNode], parents: [Int?], from index: Int) -> String? {
    for nodeIndex in ancestorChain(from: index, parents: parents) {
        if nodes[nodeIndex].className.contains("USB") {
            return "USB"
        }
    }
    return nil
}

private func ancestorString(
    _ key: String,
    from index: Int,
    nodes: [IORegNode],
    parents: [Int?]
) -> String? {
    for nodeIndex in ancestorChain(from: index, parents: parents) {
        if let value = nonEmpty(string(key, in: nodes[nodeIndex].properties)) {
            return value
        }
    }
    return nil
}

/// The IOMedia header name without the trailing " Media" that ioreg adds.
private func mediaName(_ header: String) -> String? {
    let name = header.trimmingCharacters(in: .whitespaces)
    let suffix = " Media"
    guard name.hasSuffix(suffix) else { return nonEmpty(name) }
    return nonEmpty(String(name.dropLast(suffix.count)))
}

// MARK: - Property values

private func string(_ key: String, in text: String) -> String? {
    firstGroup("\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*\"([^\"]*)\"", in: text)
}

private func dictionaryString(_ key: String, in dictionaryText: String) -> String? {
    string(key, in: dictionaryText)
}

private func integer(_ key: String, in text: String) -> Int64? {
    firstGroup("\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*([0-9]+)", in: text)
        .flatMap(Int64.init)
}

private func boolean(_ key: String, in text: String) -> Bool? {
    guard let value = firstGroup(
        "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*(Yes|No)",
        in: text
    ) else { return nil }
    return value == "Yes"
}

/// The `{...}` body of a dictionary property. With `-w 0` this is one line.
private func dictionary(_ key: String, in text: String) -> String? {
    firstGroup("\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*=\\s*\\{([^}]*)\\}", in: text)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// macOS sometimes prints `USB Serial Number` as the hex of its bytes. Decode
/// it only when every byte is printable ASCII; a hex-looking serial such as
/// `0ba01062e2bc880e` is left alone because its bytes are not text.
private func normalizedSerial(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    guard trimmed.count % 2 == 0,
          trimmed.allSatisfy({ $0.isHexDigit }),
          let bytes = hexBytes(trimmed),
          !bytes.isEmpty,
          bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E })
    else { return trimmed }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexBytes(_ value: String) -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

private func mediaType(_ value: String?) -> String? {
    switch value?.lowercased() {
    case "solid state": return "ssd"
    case "rotational", "hard disk", "hard disk drive", "magnetic": return "hdd"
    default: return nil
    }
}

// MARK: - Regex

private func firstGroup(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}
