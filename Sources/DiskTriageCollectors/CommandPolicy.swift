import Foundation

/// The read-only argv shapes triage is allowed to run (diskdoctor.md §2.7).
///
/// `TriageCommand` is the only way the product builds a command; the paths are
/// absolute so a sanitised `PATH` can never select the binary.
public enum TriageCommand: Sendable, Equatable, Hashable {
    case diskutilList
    case diskutilInfo(disk: String)
    case ioregStatistics
    /// `ioreg -r -c IOMedia -d 1 -w 0`: the association query that supplies the
    /// `BSD Name` the Statistics capture lacks.
    case ioregMedia
    case logShow(last: String, predicate: String)
    case smartctl(query: SmartQuery, node: String, deviceType: String? = nil)

    public enum SmartQuery: String, Sendable, Equatable, Hashable {
        case info = "-i"
        case health = "-H"
        case attributes = "-A"
        case all = "-a"
    }

    public var argv: [String] {
        switch self {
        case .diskutilList:
            return ["/usr/sbin/diskutil", "list", "-plist"]
        case .diskutilInfo(let disk):
            return ["/usr/sbin/diskutil", "info", "-plist", disk]
        case .ioregStatistics:
            return ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDriver", "-k", "Statistics", "-d", "1", "-w", "0"]
        case .ioregMedia:
            return ["/usr/sbin/ioreg", "-r", "-c", "IOMedia", "-d", "1", "-w", "0"]
        case .logShow(let last, let predicate):
            return ["/usr/bin/log", "show", "--last", last, "--style", "ndjson", "--predicate", predicate]
        case .smartctl(let query, let node, let deviceType):
            var argv = ["/opt/homebrew/bin/smartctl", "--json=o"]
            if let deviceType {
                argv += ["-d", deviceType]
            }
            argv += [query.rawValue, node]
            return argv
        }
    }
}

/// Why a command was rejected before `exec`.
public enum PolicyViolation: String, Codable, Sendable, Equatable {
    case notAllowListed = "not-allow-listed"
    case smartctlSelfTest = "smartctl-self-test"
    case smartctlWriteFlag = "smartctl-write-flag"
    case smartctlDeviceType = "smartctl-device-type"
    case diskNameInvalid = "disk-name-invalid"
    case logOption = "log-option"
}

public enum PolicyDecision: Sendable, Equatable {
    case allowed
    case rejected(PolicyViolation)
}

/// The fixed allow-list. Checked inside `ProcessRunner`, so a caller cannot
/// reach `exec` without passing it.
public struct CommandPolicy: Sendable {
    public static let triage = CommandPolicy()

    /// Test-only escape used to drive the real-process timeout, output and
    /// environment tests. It is internal, so no product caller can reach it.
    static let unrestrictedForTesting = CommandPolicy(allowsEverything: true)

    private let allowsEverything: Bool

    public init() {
        self.allowsEverything = false
    }

    init(allowsEverything: Bool) {
        self.allowsEverything = allowsEverything
    }

    public func evaluate(_ argv: [String]) -> PolicyDecision {
        if allowsEverything {
            return argv.isEmpty ? .rejected(.notAllowListed) : .allowed
        }
        guard let executable = argv.first, !argv.isEmpty else {
            return .rejected(.notAllowListed)
        }
        switch executable {
        case "/usr/sbin/diskutil":
            return evaluateDiskutil(Array(argv.dropFirst()))
        case "/usr/sbin/ioreg":
            let args = Array(argv.dropFirst())
            switch args {
            case ["-r", "-c", "IOBlockStorageDriver", "-k", "Statistics"],
                 ["-r", "-c", "IOBlockStorageDriver", "-k", "Statistics", "-d", "1", "-w", "0"],
                 ["-r", "-c", "IOMedia", "-d", "1", "-w", "0"]:
                return .allowed
            default:
                return .rejected(.notAllowListed)
            }
        case "/usr/bin/log":
            return evaluateLog(Array(argv.dropFirst()))
        case "/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/usr/bin/smartctl":
            return evaluateSmartctl(Array(argv.dropFirst()))
        default:
            return .rejected(.notAllowListed)
        }
    }

    private func evaluateDiskutil(_ args: [String]) -> PolicyDecision {
        if args == ["list", "-plist"] {
            return .allowed
        }
        if args.count == 3, args[0] == "info", args[1] == "-plist" {
            return isWholeDiskName(args[2]) ? .allowed : .rejected(.diskNameInvalid)
        }
        return .rejected(.notAllowListed)
    }

    private func evaluateLog(_ args: [String]) -> PolicyDecision {
        guard args.first == "show" else {
            return .rejected(.notAllowListed)
        }
        var last: String?
        var predicate: String?
        var sawStyle = false
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--last":
                guard last == nil, index + 1 < args.count else { return .rejected(.logOption) }
                last = args[index + 1]
                index += 2
            case "--predicate":
                guard predicate == nil, index + 1 < args.count else { return .rejected(.logOption) }
                predicate = args[index + 1]
                index += 2
            case "--style":
                guard !sawStyle, index + 1 < args.count, args[index + 1] == "ndjson" else {
                    return .rejected(.logOption)
                }
                sawStyle = true
                index += 2
            default:
                return .rejected(.logOption)
            }
        }
        // A window is mandatory: an unbounded `log show` can read the whole log.
        guard last != nil else { return .rejected(.logOption) }
        return .allowed
    }

    private func evaluateSmartctl(_ args: [String]) -> PolicyDecision {
        var jsonOutput = false
        var query: String?
        var node: String?
        var deviceType: String?
        var index = 0

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--json=o":
                guard !jsonOutput else { return .rejected(.notAllowListed) }
                jsonOutput = true
                index += 1
            case "-i", "-H", "-A", "-a":
                guard query == nil else { return .rejected(.notAllowListed) }
                query = argument
                index += 1
            // Self-tests start work on the drive; aborting one (-X) is still a
            // self-test operation. Never during triage (REQ-0014).
            case "-t", "--test", "-X":
                return .rejected(.smartctlSelfTest)
            case let argument where argument.hasPrefix("--test="):
                return .rejected(.smartctlSelfTest)
            // Write/configuration flags.
            case "-s", "-S", "-o", "--set", "-T":
                return .rejected(.smartctlWriteFlag)
            case "-d":
                guard index + 1 < args.count, deviceType == nil else {
                    return .rejected(.smartctlDeviceType)
                }
                let value = args[index + 1]
                guard value == "sat" || value == "auto" else {
                    return .rejected(.smartctlDeviceType)
                }
                deviceType = value
                index += 2
            default:
                guard argument.hasPrefix("/dev/"), node == nil, isDeviceNode(argument) else {
                    return .rejected(.notAllowListed)
                }
                node = argument
                index += 1
            }
        }

        guard jsonOutput, query != nil, node != nil else {
            return .rejected(.notAllowListed)
        }
        return .allowed
    }
}

func isWholeDiskName(_ name: String) -> Bool {
    guard name.hasPrefix("disk") else { return false }
    let digits = name.dropFirst(4)
    return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
}

private func isDeviceNode(_ node: String) -> Bool {
    guard node.hasPrefix("/dev/") else { return false }
    var name = String(node.dropFirst("/dev/".count))
    if name.hasPrefix("r") {
        name.removeFirst()
    }
    return isWholeDiskName(name)
}
