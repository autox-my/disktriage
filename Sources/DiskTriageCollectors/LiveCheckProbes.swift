import Foundation
import Darwin
import DiskArbitration
import DiskTriageCore

/// The live implementation of the self-test probes.
///
/// Everything that touches the machine lives here; `CheckRunner` only lays the
/// results out. The single device read is `RawDeviceProbe` on the internal
/// disk, and it is harmless (one 4096-byte read, no sudo).
public struct LiveCheckProbes: CheckProbing {
    private let executor: any CommandExecuting
    private let checkRunner: ProcessRunner
    private let environment: [String: String]

    public init(
        executor: any CommandExecuting = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executor = executor
        self.environment = environment
        // The self-test's own read-only shapes; 30 s covers the tiny log probe.
        self.checkRunner = ProcessRunner(policy: .check, timeout: 30, outputLimit: 1_048_576)
    }

    public func runningAsRoot() -> Bool {
        geteuid() == 0
    }

    public func probeRawDevice() -> FDAProbeEvidence {
        guard let node = InternalDiskLocator(executor: executor).internalRawNode() else {
            return .notRun(reason: "no internal disk found by diskutil list")
        }
        return RawDeviceProbe().probe(node: node)
    }

    public func removableVolumeAccess() -> CheckProbe {
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: "/Volumes")
            return .pass("/Volumes lists \(entries.count) entries")
        } catch {
            return .fail("cannot list /Volumes: \(error.localizedDescription)")
        }
    }

    public func tool(_ tool: CheckTool) -> CheckProbe {
        guard let path = resolve(tool.rawValue, ntfs: CheckTool.ntfsTools.contains(tool)) else {
            switch tool {
            case .smartctl, .ddrescue:
                return .fail("not found on PATH")
            default:
                return .unverifiable("not found (set DISKTRIAGE_NTFS_PREFIX or add to PATH)")
            }
        }

        let result = checkRunner.run(.toolVersion(path: path))
        switch result.outcome {
        case .ok:
            let version = result.stdout
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            guard let version, !version.isEmpty else {
                return .unverifiable("\(path) --version printed nothing")
            }
            return .pass(version)
        case .timeout:
            return .unverifiable("\(path) --version did not answer within 30 s")
        case .notFound:
            return .fail("\(path) disappeared before exec")
        case .denied:
            return .fail("\(path) --version was denied")
        case .policyRejected:
            return .fail("\(path) --version is not allow-listed")
        case .error:
            return .fail("\(path) --version exited \(result.exitCode.map(String.init) ?? "on a signal")")
        }
    }

    public func filesystemDrivers() -> CheckProbe {
        var thirdParty: [String]?
        var reason: String?
        do {
            thirdParty = try FileManager.default.contentsOfDirectory(atPath: "/Library/Filesystems")
                .filter { $0.hasSuffix(".fs") }
                .sorted()
        } catch {
            reason = error.localizedDescription
        }

        let listResult = checkRunner.run(.diskutilListFilesystems)
        let listOK = listResult.outcome == .ok

        guard listOK || thirdParty != nil else {
            return .unverifiable(
                "cannot read /Library/Filesystems (\(reason ?? "unknown")) and diskutil listFilesystems failed"
            )
        }

        let names = (thirdParty ?? []).joined(separator: ", ")
        let inventory = (thirdParty?.isEmpty ?? false) ? "none in /Library/Filesystems" : names
        let personality = listOK ? "diskutil listFilesystems readable" : "diskutil listFilesystems failed"
        return .pass("\(inventory) · \(personality)")
    }

    public func unifiedLogReadable() -> CheckProbe {
        let result = checkRunner.run(.logShowCompact(last: "1s"), timeout: 30)
        switch result.outcome {
        case .ok:
            return .pass("/usr/bin/log show --last 1s --style compact exited 0")
        case .timeout:
            return .unverifiable("/usr/bin/log did not answer within 30 s")
        case .denied:
            return .fail("/usr/bin/log was denied")
        case .notFound:
            return .fail("/usr/bin/log was not found")
        case .policyRejected:
            return .fail("the log probe is not allow-listed")
        case .error:
            return .fail("/usr/bin/log exited \(result.exitCode.map(String.init) ?? "on a signal")")
        }
    }

    public func mountGuardAvailable() -> CheckProbe {
        // Create the session only: no callback and no dissent, so this probe
        // cannot affect a plugged-in disk.
        guard DASessionCreate(kCFAllocatorDefault) != nil else {
            return .fail("DASessionCreate returned nil")
        }
        return .pass("DASession created; no callback registered")
    }

    public func sleepPrevention() -> CheckProbe {
        let candidates = ["/usr/bin/caffeinate", "/usr/sbin/caffeinate"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .fail("caffeinate not found")
        }
        return .pass(path)
    }

    public func diskArbitrationDaemon() -> CheckProbe {
        guard let output = processList() else {
            return .unverifiable("ps could not be run")
        }
        let line = output
            .split(whereSeparator: \.isNewline)
            .first { $0.contains("diskarbitrationd") }
        guard let line else {
            return .fail("diskarbitrationd is not running")
        }
        let fields = line.split(whereSeparator: \.isWhitespace)
        let stat = fields.count > 1 ? String(fields[1]) : "?"
        if stat.contains("T") {
            return .fail("diskarbitrationd is stopped (stat \(stat))")
        }
        return .pass("running (stat \(stat))")
    }

    public func terminal() -> TerminalIdentity {
        TerminalDetector.liveIdentity(environment: environment)
    }

    // MARK: - Resolution

    /// `DISKTRIAGE_NTFS_PREFIX` first (the bench-built tree is not assumed),
    /// then PATH, then the usual Homebrew and system directories. The ntfs-3g
    /// names use the shared locator `inspect` also uses, so the self-test and
    /// inspection cannot drift apart.
    private func resolve(_ name: String, ntfs: Bool) -> String? {
        if ntfs {
            return NTFSToolLocator.resolve(name, environment: environment)
        }
        var directories: [String] = []
        if let path = environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/sbin"]

        var seen: Set<String> = []
        for directory in directories where seen.insert(directory).inserted {
            let candidate = directory.hasSuffix("/") ? directory + name : directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func processList() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,stat=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
