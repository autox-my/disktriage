import Foundation

/// One whole-disk `IOMedia` node from `ioreg -r -c IOMedia -d 1 -w 0`.
///
/// The `-k Statistics` capture names its child `IOMedia` only by registry id,
/// so this second recording is what supplies the `BSD Name` the plan requires
/// (`diskdoctor.md` §4, P0 runbook B2).
public struct IORegMedia: Equatable, Sendable {
    public let nodeID: String?
    public let name: String?
    public let bsdName: String?
    public let whole: Bool?

    public init(nodeID: String? = nil, name: String? = nil, bsdName: String? = nil, whole: Bool? = nil) {
        self.nodeID = nodeID
        self.name = name
        self.bsdName = bsdName
        self.whole = whole
    }
}

/// Parses the text of `ioreg -r -c IOMedia -d 1 -w 0`. Pure string to value;
/// no process is run here.
///
/// Only unindented `+-o` blocks are read: with `-d 1` those are the whole
/// media roots, while slices and volumes are nested below them.
public enum IORegMediaParser {
    public static func parse(_ text: String) throws -> [IORegMedia] {
        var media: [IORegMedia] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            let block = current.joined(separator: "\n")
            if let header = firstMatch(
                #"^\+-o (.+?)  <class IOMedia, id (0x[0-9a-fA-F]+)"#,
                in: current[0]
            ) {
                media.append(
                    IORegMedia(
                        nodeID: header[2],
                        name: header[1],
                        bsdName: firstMatch(#""BSD Name" = "([^"]+)""#, in: block)?[1],
                        whole: firstMatch(#""Whole" = (Yes|No)"#, in: block)?[1].map { $0 == "Yes" }
                    )
                )
            }
            current = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if value.hasPrefix("+-o ") {
                flush()
                current = [value]
            } else if !current.isEmpty {
                current.append(value)
            }
        }
        flush()
        return media
    }
}

private func firstMatch(_ pattern: String, in text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
        return nil
    }
    return (0..<match.numberOfRanges).map { index in
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
