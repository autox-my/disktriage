import Foundation
import Darwin

/// Finds the process TCC will attribute a raw-device read to. For a CLI in a
/// terminal that is the terminal application (diskdoctor.md §7, option A).
///
/// `identity(ancestors:termProgram:)` is pure and tested; `liveIdentity()` is
/// the only part that looks at this machine.
public enum TerminalDetector {

    /// `ancestors` is nearest-first: the parent, then its parent, and so on.
    public static func identity(ancestors: [String], termProgram: String?) -> TerminalIdentity {
        let termProgramPresent = !(termProgram ?? "").isEmpty
        for path in ancestors {
            if let identity = appBundleIdentity(path: path, termProgramPresent: termProgramPresent) {
                return identity
            }
        }
        if let termProgram, !termProgram.isEmpty {
            return TerminalIdentity(name: displayName(for: termProgram), bundlePath: nil, isTerminal: true)
        }
        return .unidentified
    }

    /// `/Applications/Ghostty.app/Contents/MacOS/ghostty` →
    /// name `Ghostty`, bundle `/Applications/Ghostty.app`.
    public static func appBundleIdentity(
        path: String,
        termProgramPresent: Bool = false
    ) -> TerminalIdentity? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        let name = (bundle as NSString).lastPathComponent
        let display = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        guard !display.isEmpty else { return nil }
        return TerminalIdentity(
            name: display,
            bundlePath: bundle,
            isTerminal: termProgramPresent || terminalNames.contains(display)
        )
    }

    /// Terminal applications whose bundle name is unambiguous. A GUI host that
    /// merely spawned the CLI is not in this set.
    private static let terminalNames: Set<String> = [
        "Terminal", "iTerm", "Ghostty", "WezTerm", "kitty", "Hyper",
        "Alacritty", "Tabby", "Visual Studio Code",
    ]

    /// The values `TERM_PROGRAM` actually takes on macOS.
    public static func displayName(for termProgram: String) -> String {
        switch termProgram.lowercased() {
        case "apple_terminal": return "Terminal"
        case "iterm.app": return "iTerm"
        case "ghostty": return "Ghostty"
        case "vscode": return "Visual Studio Code"
        case "wezterm": return "WezTerm"
        case "kitty": return "kitty"
        case "hyper": return "Hyper"
        case "tabby": return "Tabby"
        case "alacritty": return "Alacritty"
        default: return termProgram
        }
    }

    /// Walks this process's parent chain and reads each executable path. The
    /// walk is bounded so a broken process table cannot spin.
    public static func liveIdentity(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalIdentity {
        identity(
            ancestors: liveAncestors(),
            termProgram: environment["TERM_PROGRAM"]
        )
    }

    public static func liveAncestors(limit: Int = 32) -> [String] {
        var ancestors: [String] = []
        var pid = getppid()
        var seen: Set<pid_t> = []

        for _ in 0..<limit {
            guard pid > 1, !seen.contains(pid) else { break }
            seen.insert(pid)
            if let path = executablePath(of: pid) {
                ancestors.append(path)
            }
            guard let parent = parentProcess(of: pid), parent != pid, parent > 1 else { break }
            pid = parent
        }
        return ancestors
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPointer in
            withUnsafeMutablePointer(to: &info) { infoPointer in
                sysctl(mibPointer.baseAddress, 4, infoPointer, &size, nil, 0)
            }
        }
        guard result == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
