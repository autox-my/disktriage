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
    /// `ioreg -r -c IOBlockStorageDevice -w 0 -l`: the identity path that does
    /// not depend on DiskArbitration. The device node carries product/vendor/
    /// serial and its subtree carries the whole-disk IOMedia.
    case ioregDeviceTree
    /// `ioreg -r -c IOMedia -w 0`: the full media tree, whose parent links walk
    /// an APFS volume through its synthesized container to its physical store.
    case ioregMediaTree
    /// `ioreg -r -c IOUSBHostDevice -w 0 -l`: the same tree rooted at the USB
    /// host device, which carries the serial string a bridge hides.
    case ioregUSBDeviceTree
    /// `pgrep -x diskarbitrationd`, the same argv the guard uses.
    case pgrepDiskArbitrationDaemon
    /// `ps -o stat= -p <pid>`, the same argv the guard uses to verify state T.
    case processState(pid: Int32)
    case logShow(last: String, predicate: String)
    case smartctl(query: SmartQuery, node: String, deviceType: String? = nil)
    /// `disktriage check`: the filesystem personality inventory.
    case diskutilListFilesystems
    /// `disktriage check`: a tiny readability probe, not evidence collection.
    case logShowCompact(last: String)
    /// `disktriage check`: a resolved tool's `--version`.
    case toolVersion(path: String)
    /// `disktriage inspect`: one read-only ntfs-3g tool invocation. The path is
    /// resolved (absolute) by the caller so a sanitised PATH cannot choose it.
    case ntfsTool(path: String, arguments: [String])
    /// The native read-only attach of an image (docs/adr/0025): `diskutil
    /// image attach --noMount --readOnly <image>`. The image is an absolute
    /// file path outside `/dev`.
    case nativeAttach(image: String)
    /// The explicit read-only mount of one attached volume at our own
    /// mountpoint: `diskutil mount readOnly nobrowse -mountPoint <dir> <dev>`.
    case nativeMount(volume: String, mountPoint: String)
    /// `diskutil unmount <dev>`: the exact volume this run mounted.
    case nativeUnmount(volume: String)
    /// `diskutil eject <dev>`: the exact whole disk this run attached.
    case nativeDetach(wholeDisk: String)
    /// `diskutil info -plist <dev>`: the volume name, filesystem and lock
    /// state, read-only.
    case nativeInfo(device: String)
    /// `hdiutil info`: the read-only image inventory used only to recover the
    /// device node of an image whose attach timed out.
    case hdiutilInfo

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
            // `-k Statistics` prunes the child IOMedia entry on macOS 27.2, and
            // without that entry the driver cannot be associated with a disk.
            // The unfiltered query still carries the `Statistics` property.
            return ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDriver", "-w", "0"]
        case .ioregMedia:
            return ["/usr/sbin/ioreg", "-r", "-c", "IOMedia", "-d", "1", "-w", "0"]
        case .ioregDeviceTree:
            return ["/usr/sbin/ioreg", "-r", "-c", "IOBlockStorageDevice", "-w", "0", "-l"]
        case .ioregMediaTree:
            return ["/usr/sbin/ioreg", "-r", "-c", "IOMedia", "-w", "0"]
        case .ioregUSBDeviceTree:
            return ["/usr/sbin/ioreg", "-r", "-c", "IOUSBHostDevice", "-w", "0", "-l"]
        case .pgrepDiskArbitrationDaemon:
            return ["/usr/bin/pgrep", "-x", "diskarbitrationd"]
        case .processState(let pid):
            return ["/bin/ps", "-o", "stat=", "-p", String(pid)]
        case .logShow(let last, let predicate):
            return ["/usr/bin/log", "show", "--last", last, "--style", "ndjson", "--predicate", predicate]
        case .smartctl(let query, let node, let deviceType):
            var argv = ["/opt/homebrew/bin/smartctl", "--json=o"]
            if let deviceType {
                argv += ["-d", deviceType]
            }
            argv += [query.rawValue, node]
            return argv
        case .diskutilListFilesystems:
            return ["/usr/sbin/diskutil", "listFilesystems"]
        case .logShowCompact(let last):
            return ["/usr/bin/log", "show", "--last", last, "--style", "compact"]
        case .toolVersion(let path):
            return [path, "--version"]
        case .ntfsTool(let path, let arguments):
            return [path] + arguments
        case .nativeAttach(let image):
            return ["/usr/sbin/diskutil", "image", "attach", "--noMount", "--readOnly", image]
        case .nativeMount(let volume, let mountPoint):
            return ["/usr/sbin/diskutil", "mount", "readOnly", "nobrowse", "-mountPoint", mountPoint, volume]
        case .nativeUnmount(let volume):
            return ["/usr/sbin/diskutil", "unmount", volume]
        case .nativeDetach(let wholeDisk):
            return ["/usr/sbin/diskutil", "eject", wholeDisk]
        case .nativeInfo(let device):
            return ["/usr/sbin/diskutil", "info", "-plist", device]
        case .hdiutilInfo:
            return ["/usr/bin/hdiutil", "info"]
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
    case logPredicate = "log-predicate"
}

public enum PolicyDecision: Sendable, Equatable {
    case allowed
    case rejected(PolicyViolation)
}

/// The fixed allow-list. Checked inside `ProcessRunner`, so a caller cannot
/// reach `exec` without passing it.
public struct CommandPolicy: Sendable {
    public static let triage = CommandPolicy()
    /// The self-test's narrower additions: `--version`, `listFilesystems` and
    /// a tiny compact `log show`. These shapes are never available to triage.
    public static let check = CommandPolicy(kind: .check)
    /// `inspect`: only the read-only ntfs-3g shapes, on an image file.
    public static let inspect = CommandPolicy(kind: .inspect)
    /// `inspect`/`copy` for a native filesystem: the exact read-only attach,
    /// mount, unmount, detach and info shapes (docs/adr/0025). This is the only
    /// policy that may name `mount`, `unmount` or `eject`, and only for an
    /// image this run attached.
    public static let native = CommandPolicy(kind: .native)

    /// Test-only escape used to drive the real-process timeout, output and
    /// environment tests. It is internal, so no product caller can reach it.
    static let unrestrictedForTesting = CommandPolicy(allowsEverything: true)

    private enum Kind: Sendable {
        case triage
        case check
        case inspect
        case native
    }

    private let allowsEverything: Bool
    private let kind: Kind

    public init() {
        self.allowsEverything = false
        self.kind = .triage
    }

    init(allowsEverything: Bool) {
        self.allowsEverything = allowsEverything
        self.kind = .triage
    }

    private init(kind: Kind) {
        self.allowsEverything = false
        self.kind = kind
    }

    public func evaluate(_ argv: [String]) -> PolicyDecision {
        if allowsEverything {
            return argv.isEmpty ? .rejected(.notAllowListed) : .allowed
        }
        guard let executable = argv.first, !argv.isEmpty else {
            return .rejected(.notAllowListed)
        }
        if kind == .inspect {
            return evaluateNtfsTool(argv)
        }
        if kind == .native {
            return evaluateNative(argv)
        }
        switch executable {
        case "/usr/sbin/diskutil":
            return evaluateDiskutil(Array(argv.dropFirst()))
        case "/usr/sbin/ioreg":
            let args = Array(argv.dropFirst())
            switch args {
            case ["-r", "-c", "IOBlockStorageDriver", "-k", "Statistics"],
                 ["-r", "-c", "IOBlockStorageDriver", "-k", "Statistics", "-d", "1", "-w", "0"],
                 ["-r", "-c", "IOBlockStorageDriver", "-w", "0"],
                 ["-r", "-c", "IOMedia", "-d", "1", "-w", "0"],
                 ["-r", "-c", "IOMedia", "-w", "0"],
                 ["-r", "-c", "IOBlockStorageDevice", "-w", "0", "-l"],
                 ["-r", "-c", "IOUSBHostDevice", "-w", "0", "-l"]:
                return .allowed
            default:
                return .rejected(.notAllowListed)
            }
        case "/usr/bin/pgrep":
            return Array(argv.dropFirst()) == ["-x", "diskarbitrationd"]
                ? .allowed
                : .rejected(.notAllowListed)
        case "/bin/ps":
            let args = Array(argv.dropFirst())
            guard args.count == 4,
                  args[0] == "-o",
                  args[1] == "stat=",
                  args[2] == "-p",
                  let pid = Int32(args[3]),
                  pid > 0
            else {
                return .rejected(.notAllowListed)
            }
            return .allowed
        case "/usr/bin/log":
            return evaluateLog(Array(argv.dropFirst()))
        case "/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl", "/usr/bin/smartctl":
            return kind == .check ? evaluateCheckTool(argv) : evaluateSmartctl(Array(argv.dropFirst()))
        default:
            if kind == .check {
                return evaluateCheckTool(argv)
            }
            return .rejected(.notAllowListed)
        }
    }

    /// Inspect/copy-only: the exact read-only shapes the NTFS tools use. The
    /// image must be an absolute path outside `/dev`; `-f/--force`, `ntfsfix`
    /// and any other tool are rejected before exec. `ntfscat` reads one file,
    /// `ntfscluster -c <range> -v` is the one-pass run map, and `ntfsls -l -R`
    /// is the recursive listing with sizes.
    private func evaluateNtfsTool(_ argv: [String]) -> PolicyDecision {
        guard argv.count >= 3, argv[0].hasPrefix("/") else {
            return .rejected(.notAllowListed)
        }
        let tool = (argv[0] as NSString).lastPathComponent
        switch tool {
        case "ntfsinfo":
            guard argv.count == 3, argv[1] == "-m", isSafeImage(argv[2]) else {
                return .rejected(.notAllowListed)
            }
            return .allowed
        case "ntfsls":
            let args = Array(argv.dropFirst())
            guard args.count == 2 || args.count == 3 else {
                return .rejected(.notAllowListed)
            }
            let image = args[args.count - 1]
            let flags = Array(args.dropLast())
            let validFlags = flags == ["-l"] || flags == ["-R"] || flags == ["-l", "-R"]
            return validFlags && isSafeImage(image) ? .allowed : .rejected(.notAllowListed)
        case "ntfscat":
            // ntfscat [options] device [file]
            guard argv.count == 3, isSafeImage(argv[1]), isSafeVolumePath(argv[2]) else {
                return .rejected(.notAllowListed)
            }
            return .allowed
        case "ntfscluster":
            guard argv.count == 5,
                  argv[1] == "-c",
                  isClusterRange(argv[2]),
                  argv[3] == "-v",
                  isSafeImage(argv[4])
            else {
                return .rejected(.notAllowListed)
            }
            return .allowed
        default:
            return .rejected(.notAllowListed)
        }
    }

    /// An image argument is absolute and never a device node.
    private func isSafeImage(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("/dev/")
    }

    /// A volume path for `ntfscat`: absolute-looking, a real file path, and no
    /// `..` component. A leading `-` is a flag, so it is rejected by the `/`.
    private func isSafeVolumePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let relative = path.dropFirst()
        guard !relative.isEmpty else { return false }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `0-16382`, never a flag or a comma list.
    private func isClusterRange(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let first = Int64(parts[0]),
              let last = Int64(parts[1]),
              first >= 0, last >= first
        else { return false }
        return true
    }

    /// Native-only: the exact shapes `NativeAttachRunner` builds. There is no
    /// writable mount, no `-mountOptions`, no `--force`, no third-party driver,
    /// no `--stdinpassphrase`, and no wildcard: every argument is checked.
    private func evaluateNative(_ argv: [String]) -> PolicyDecision {
        if argv.first == "/usr/bin/hdiutil" {
            return argv.dropFirst().elementsEqual(["info"]) ? .allowed : .rejected(.notAllowListed)
        }
        guard argv.first == "/usr/sbin/diskutil" else { return .rejected(.notAllowListed) }
        let args = Array(argv.dropFirst())

        if args.count == 5, args[0] == "image", args[1] == "attach",
           args[2] == "--noMount", args[3] == "--readOnly",
           isSafeNativeFile(args[4]) {
            return .allowed
        }
        if args.count == 6, args[0] == "mount", args[1] == "readOnly", args[2] == "nobrowse",
           args[3] == "-mountPoint", isSafeMountPoint(args[4]),
           isMountableDevice(args[5]) {
            return .allowed
        }
        if args.count == 2, args[0] == "unmount", isMountableDevice(args[1]) {
            return .allowed
        }
        if args.count == 2, args[0] == "eject", args[1].hasPrefix("/dev/"),
           isWholeDiskName(deviceName(args[1])) {
            return .allowed
        }
        if args.count == 3, args[0] == "info", args[1] == "-plist", isMountableDevice(args[2]) {
            return .allowed
        }
        return .rejected(.notAllowListed)
    }

    /// An absolute image path outside `/dev`; the attach never names a device.
    private func isSafeNativeFile(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("/dev/") && !path.contains("\0")
    }

    /// An absolute mountpoint outside `/dev`; the caller creates it.
    private func isSafeMountPoint(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("/dev/") && !path.contains("\0")
    }

    /// `/dev/diskN` or `/dev/diskN sM`, never a raw (`rdisk`) node.
    private func isMountableDevice(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/") else { return false }
        let name = deviceName(path)
        return isWholeDiskName(name) || isVolumeDeviceName(name)
    }

    private func deviceName(_ path: String) -> String {
        path.hasPrefix("/dev/") ? String(path.dropFirst("/dev/".count)) : path
    }

    /// `disk12s34`: a partition or a synthesized APFS volume.
    private func isVolumeDeviceName(_ name: String) -> Bool {
        guard name.hasPrefix("disk") else { return false }
        let rest = name.dropFirst(4)
        guard let split = rest.firstIndex(of: "s") else { return false }
        let disk = rest[..<split]
        let slice = rest[rest.index(after: split)...]
        return !disk.isEmpty && disk.allSatisfy { $0.isASCII && $0.isNumber }
            && !slice.isEmpty && slice.allSatisfy { $0.isASCII && $0.isNumber }
    }


    /// Check-only: a resolved absolute tool path and exactly `--version`. The
    /// basename is the allow-list, so a random binary cannot be executed.
    private func evaluateCheckTool(_ argv: [String]) -> PolicyDecision {
        let allowListed = ["smartctl", "ddrescue", "ntfsinfo", "ntfsls", "ntfscat", "ntfscluster"]
        guard argv.count == 2,
              argv[1] == "--version",
              argv[0].hasPrefix("/"),
              allowListed.contains((argv[0] as NSString).lastPathComponent)
        else {
            return .rejected(.notAllowListed)
        }
        return .allowed
    }

    private func evaluateDiskutil(_ args: [String]) -> PolicyDecision {
        if args == ["list", "-plist"] {
            return .allowed
        }
        if kind == .check, args == ["listFilesystems"] {
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
        if kind == .check {
            return evaluateCompactLog(args)
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
        // ndjson is the shape the parser reads. A predicate is mandatory too:
        // an unrestricted query can walk the whole log, and a predicate other
        // than the kernel one was measured at ~117 s for 6 h.
        guard sawStyle else { return .rejected(.logOption) }
        guard predicate == KernelLogCollector.predicate else { return .rejected(.logPredicate) }
        return .allowed
    }

    /// Check-only: exactly `log show --last <window> --style compact`, with a
    /// bounded window and no predicate. It is a readability probe, not a
    /// collection query.
    private func evaluateCompactLog(_ args: [String]) -> PolicyDecision {
        guard args.count == 5,
              args[1] == "--last",
              args[3] == "--style",
              args[4] == "compact",
              isBoundedWindow(args[2])
        else {
            return .rejected(.logOption)
        }
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

/// A `--last` window such as `1s`, `30m`, `12h` or `7d`; never `all`.
private func isBoundedWindow(_ value: String) -> Bool {
    guard let unit = value.last, "smhd".contains(unit), value.count > 1 else { return false }
    return value.dropLast().allSatisfy { $0.isASCII && $0.isNumber }
}
