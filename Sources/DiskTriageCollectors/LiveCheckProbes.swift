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
    /// The tool-version probe runs under the check policy, which is wider than
    /// triage's. Injected with the executor in tests so no binary is executed.
    private let checkRunner: any CommandExecuting
    private let environment: [String: String]
    /// The running executable's path, resolved for the keg-relative libexec
    /// lookup. Injected in tests; `Bundle.main.executablePath` in production.
    private let executablePath: String?
    /// `/Volumes` is listed through this seam, names only. A hung network mount
    /// makes every attribute lookup block, so the lister never resolves one.
    private let volumeLister: any VolumeListing
    /// The hard bound on that listing. A listing that does not answer is a
    /// timeout row (UNVERIFIABLE), never PASS.
    private let volumeListTimeout: TimeInterval

    public init(
        executor: any CommandExecuting = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        versionRunner: (any CommandExecuting)? = nil,
        executablePath: String? = Bundle.main.executablePath,
        volumeLister: any VolumeListing = POSIXVolumeLister(),
        volumeListTimeout: TimeInterval = 2
    ) {
        self.executor = executor
        self.environment = environment
        self.executablePath = executablePath
        self.volumeLister = volumeLister
        self.volumeListTimeout = volumeListTimeout
        // The self-test's own read-only shapes; 30 s covers the tiny log probe.
        self.checkRunner = versionRunner
            ?? ProcessRunner(policy: .check, timeout: 30, outputLimit: 1_048_576)
    }

    public func runningAsRoot() -> Bool {
        geteuid() == 0
    }

    public func probeRawDevice() -> FDAProbeEvidence {
        guard let node = InternalDiskLocator(executor: executor).internalRawNode() else {
            return .notRun(reason: "no internal disk found by diskutil or ioreg")
        }
        return RawDeviceProbe().probe(node: node)
    }

    public func removableVolumeAccess() -> CheckProbe {
        // Names come from readdir, never `contentsOfDirectory`: the latter
        // resolves entry metadata and blocks forever beside a hung WebDAV
        // mount. The listing itself still gets a hard bound, and a timeout is
        // UNVERIFIABLE — an absent signal is never a pass.
        switch boundedVolumeListing(
            using: volumeLister,
            path: "/Volumes",
            within: volumeListTimeout
        ) {
        case .timedOut:
            let bound = String(format: "%g", volumeListTimeout)
            return .unverifiable("/Volumes did not answer within \(bound) s (hung mount?)")
        case .listed(.failed(let reason)):
            return .fail("cannot list /Volumes: \(reason)")
        case .listed(.names(let entries)):
            return .pass("/Volumes lists \(entries.count) entries")
        }
    }

    public func tool(_ tool: CheckTool) -> CheckProbe {
        let ntfs = CheckTool.ntfsTools.contains(tool)
        guard let path = resolve(tool.rawValue, ntfs: ntfs) else {
            // The searched directories are part of the message: the real run
            // said "missing ntfsls" while inspect found it under the same
            // prefix, which is a different claim from "not on any search path".
            switch tool {
            case .smartctl, .ddrescue:
                return .fail("not found on PATH (searched \(searchDescription(ntfs: ntfs)))")
            default:
                return .unverifiable("not found (searched \(searchDescription(ntfs: ntfs)))")
            }
        }

        let result = checkRunner.run(.toolVersion(path: path))
        switch result.outcome {
        case .ok:
            // ntfs-3g's ntfscat prints its banner on stderr (measured).
            guard let version = firstLine(result.stdout) ?? (ntfs ? firstLine(result.stderr) : nil) else {
                return .unverifiable("\(path) --version printed nothing")
            }
            // The ntfs row names the location as well as the version: the
            // Homebrew keg's libexec is not on PATH, so "found" must say where.
            return .pass(ntfs ? "\(version) (at \(path))" : version)
        case .timeout:
            return .unverifiable("\(path) --version did not answer within 30 s")
        case .notFound:
            return .fail("\(path) disappeared before exec")
        case .denied:
            return .fail("\(path) --version was denied")
        case .policyRejected:
            return .fail("\(path) --version is not allow-listed")
        case .error:
            let code = result.exitCode.map(String.init) ?? "on a signal"
            // ntfs-3g's `ntfsls --version` prints its banner and exits 1. A
            // found, runnable binary is present even when the version flag's
            // exit status is not 0; it is never reported as "missing".
            if ntfs, let line = firstLine(result.stdout) ?? firstLine(result.stderr),
               line.lowercased().contains(tool.rawValue) {
                return .pass("\(line) (found at \(path); --version exited \(code))")
            }
            if ntfs {
                return .unverifiable("found at \(path), but --version exited \(code)")
            }
            return .fail("\(path) --version exited \(code)")
        }
    }

    public func filesystemDrivers() -> CheckProbe {
        // While DiskArbitration is stopped, any `diskutil` call hangs
        // system-wide (P0 phase C). The row is UNVERIFIABLE, never a wait.
        let daemon = DiskArbitrationProbe(executor: executor, environment: environment)
        if daemon.forceIOReg {
            return .unverifiable(DiskArbitrationProbe.forcedReason)
        }
        if daemon.isStopped() {
            // The row's own wording, as the CLI contract states it.
            return .unverifiable("diskarbitrationd stopped; diskutil skipped")
        }

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
        // DASessionCreate is a synchronous DiskArbitration call. With the
        // daemon SIGSTOPped it waits with no timeout — the measured `check`
        // hang — so the row is UNVERIFIABLE and never makes the call.
        let daemon = DiskArbitrationProbe(executor: executor, environment: environment)
        if daemon.isStopped() {
            return .unverifiable("diskarbitrationd stopped; DASessionCreate skipped")
        }
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
        // The guard's own argv shapes, through the injected runner: `pgrep`
        // and `ps` are bounded by the runner's hard timeout, unlike the bare
        // `Process` this row used to run with no deadline.
        let pidResult = executor.run(.pgrepDiskArbitrationDaemon)
        guard pidResult.outcome == .ok,
              let pid = pidResult.stdout
                  .split(whereSeparator: \.isWhitespace)
                  .first
                  .flatMap({ Int32($0) })
        else {
            if pidResult.outcome == .error, pidResult.exitCode == 1 {
                return .fail("diskarbitrationd is not running")
            }
            if pidResult.outcome == .timeout {
                return .unverifiable("pgrep did not answer within its hard timeout")
            }
            return .unverifiable("pgrep could not be run (\(pidResult.outcome.rawValue))")
        }

        let stateResult = executor.run(.processState(pid: pid))
        guard stateResult.outcome == .ok else {
            if stateResult.outcome == .timeout {
                return .unverifiable("ps did not answer within its hard timeout")
            }
            return .unverifiable("ps could not read the state of diskarbitrationd")
        }
        let stat = stateResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stat.isEmpty else {
            return .unverifiable("ps printed no state for diskarbitrationd")
        }
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
    /// then the installing keg's `libexec/ntfs-3g` beside the resolved
    /// executable, then PATH and the usual Homebrew and system directories.
    /// The ntfs-3g names use the shared locator `inspect` also uses, so the
    /// self-test and inspection cannot drift apart.
    private func resolve(_ name: String, ntfs: Bool) -> String? {
        if ntfs {
            return NTFSToolLocator.resolve(
                name,
                environment: environment,
                executablePath: executablePath
            )
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

    /// The directories the tool lookup actually visits, in order. A failure
    /// that does not name them turns "the prefix was not exported" into
    /// "the tool is missing".
    private func searchDescription(ntfs: Bool) -> String {
        if ntfs {
            return NTFSToolLocator.searchDescription(
                environment: environment,
                executablePath: executablePath
            )
        }
        return "PATH, /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin, /sbin"
    }

    private func firstLine(_ text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}
