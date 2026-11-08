import Foundation
import DiskTriageCore
import DiskTriageCollectors

/// The injectable side of `inspect`: the filesystem (real temporary images in
/// tests) and the ntfs-3g runner (recorded output in tests).
public struct InspectDependencies: Sendable {
    public var fileSystem: any InspectFileSystem
    public var environment: [String: String]
    public var tools: (any NTFSToolRunning)?
    /// `false` with `tools == nil` means "pretend the tools are not installed",
    /// which is how the missing-tools precondition is tested without depending
    /// on what this host has in `/opt/homebrew/bin`.
    public var resolveTools: Bool
    /// The directory a relative path argument is resolved against. Injected so
    /// the tests never change the process's working directory, which is global
    /// state a parallel suite must not touch.
    public var currentDirectory: String
    /// The running executable, resolved for the keg-relative libexec lookup.
    public var executablePath: String?
    /// The native read-only attach (APFS/HFS+/exFAT/FAT). Injected in tests;
    /// `nil` with `resolveNative == true` means the live runner when
    /// `/usr/sbin/diskutil` exists.
    public var native: (any NativeAttachRunning)?
    /// The mounted-tree reader. Injected in tests; the live reader is the real
    /// filesystem under the mountpoint.
    public var mountReader: (any MountedVolumeReading)?
    /// `false` with `native == nil` means "pretend the native runner is not
    /// available", which is how the missing-tool precondition is tested.
    public var resolveNative: Bool
    /// Install the SIGINT/SIGTERM cleanup trap. Off in tests, on live.
    public var installSignalTrap: Bool
    /// Where mountpoint directories are created. `nil` is the system temp
    /// directory; every mountpoint is removed before the command returns.
    public var mountPointRoot: String?

    public init(
        fileSystem: any InspectFileSystem = LiveInspectFileSystem(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tools: (any NTFSToolRunning)? = nil,
        resolveTools: Bool = true,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        executablePath: String? = Bundle.main.executablePath,
        native: (any NativeAttachRunning)? = nil,
        mountReader: (any MountedVolumeReading)? = nil,
        resolveNative: Bool = true,
        installSignalTrap: Bool = true,
        mountPointRoot: String? = nil
    ) {
        self.fileSystem = fileSystem
        self.environment = environment
        self.tools = tools
        self.resolveTools = resolveTools
        self.currentDirectory = currentDirectory
        self.executablePath = executablePath
        self.native = native
        self.mountReader = mountReader
        self.resolveNative = resolveNative
        self.installSignalTrap = installSignalTrap
        self.mountPointRoot = mountPointRoot
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String? = Bundle.main.executablePath
    ) -> InspectDependencies {
        InspectDependencies(
            fileSystem: LiveInspectFileSystem(),
            environment: environment,
            executablePath: executablePath
        )
    }
}

/// `disktriage inspect <image> [--mapfile <path>] [--json]
/// [--restore-boot-sector --to <working-copy>]` (diskdoctor.md §6, §8).
///
/// v1 is NTFS only: the ntfs-3g userspace tools read the image, no mount and no
/// kernel filesystem path. Exit 0 inspected without a damage note, 1 inspected
/// but the mapfile reports damage or the volume only partly opened, 30 a
/// precondition or tool error. The verdict codes 10–13, 20 and 21 are not
/// inspect's to return.
public func runInspect(arguments: [String], dependencies: InspectDependencies? = nil) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(inspectUsage)
    }

    var options = InspectOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--mapfile":
            guard index + 1 < arguments.count else {
                return usageError("--mapfile needs a path")
            }
            options.mapfile = arguments[index + 1]
            index += 2
        case "--to":
            guard index + 1 < arguments.count else {
                return usageError("--to needs the working-copy path")
            }
            options.workingCopy = arguments[index + 1]
            index += 2
        case "--restore-boot-sector":
            options.restoreBootSector = true
            index += 1
        case "--json":
            options.asJSON = true
            index += 1
        default:
            let argument = arguments[index]
            if argument.hasPrefix("-") {
                return usageError("unknown option '\(argument)'")
            }
            guard options.image == nil else {
                return usageError("inspect takes one image, not '\(argument)'")
            }
            options.image = argument
            index += 1
        }
    }

    guard let rawImage = options.image else {
        return usageError("inspect needs an image file (it inspects images only, never /dev/*)")
    }

    let dependencies = dependencies ?? .live()
    // The command policy is absolute-only, so a relative path is a CLI concern:
    // it is resolved against the working directory before the policy sees it.
    let image = InspectPathRules.absolute(rawImage, currentDirectory: dependencies.currentDirectory)
    let workingCopy = options.workingCopy.map {
        InspectPathRules.absolute($0, currentDirectory: dependencies.currentDirectory)
    }
    let mapfile = options.mapfile.map {
        InspectPathRules.absolute($0, currentDirectory: dependencies.currentDirectory)
    }

    if let refusal = deviceNodeRefusal(
        argument: rawImage,
        resolved: image,
        prefix: "inspect accepts an image file, not a device node",
        suffix: ". Image the device first; inspect never reads /dev/*."
    ) {
        return refusal
    }
    if let raw = options.workingCopy, let workingCopy, let refusal = deviceNodeRefusal(
        argument: raw,
        resolved: workingCopy,
        prefix: "--to must be a working-copy file, not a device node",
        suffix: ""
    ) {
        return refusal
    }
    if let raw = options.mapfile, let mapfile, let refusal = deviceNodeRefusal(
        argument: raw,
        resolved: mapfile,
        prefix: "--mapfile must be a file, not a device node",
        suffix: ""
    ) {
        return refusal
    }
    if options.restoreBootSector && workingCopy == nil {
        return usageError("--restore-boot-sector needs --to <working-copy>: the original image is never written")
    }
    if workingCopy != nil && !options.restoreBootSector {
        return usageError("--to is only used with --restore-boot-sector")
    }
    if let workingCopy, workingCopy == image {
        return usageError("--to must be a new path, not the image being inspected")
    }

    options.image = image
    options.workingCopy = workingCopy
    options.mapfile = mapfile
    return inspect(image: image, options: options, dependencies: dependencies)
}

// MARK: - Paths

/// CLI path rules. `absolute` resolves a relative argument against the working
/// directory and removes `.`/`..` without following symlinks, so the path the
/// user sees is the path in the report. `resolvingSymlinks` is used only for
/// the `/dev` refusal: an ordinary-looking symlink to `/dev/rdiskN` is still a
/// device node.
enum InspectPathRules {
    static func absolute(_ path: String, currentDirectory: String) -> String {
        guard !path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let base = currentDirectory.hasSuffix("/") ? currentDirectory : currentDirectory + "/"
        return URL(fileURLWithPath: base + path).standardizedFileURL.path
    }

    static func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

func deviceNodeRefusal(
    argument: String,
    resolved: String,
    prefix: String,
    suffix: String
) -> CLIResult? {
    let target = InspectPathRules.resolvingSymlinks(resolved)
    guard isDevicePath(resolved) || isDevicePath(target) else { return nil }
    let resolvedNote = target == resolved ? "" : " (resolves to '\(target)')"
    return usageError("\(prefix): '\(argument)'\(resolvedNote)\(suffix)")
}

// MARK: - Options

struct InspectOptions {
    var image: String?
    var mapfile: String?
    var workingCopy: String?
    var restoreBootSector = false
    var asJSON = false
}

// MARK: - Report

enum InspectStatus: String {
    case ok
    case damage
    case partial
    case toolError = "tool-error"
    case unsupported
}

/// Shared with `copy`: the same partition parse decides what the tools see.
struct LayoutReport {
    let kind: String
    let scheme: PartitionScheme?
    let partition: Int?
    let offsetBytes: Int64
    let lengthBytes: Int64
    let availableBytes: Int64
    let extracted: Bool

    var isWholeDisk: Bool { kind == "whole-disk" }
    var partial: Bool { availableBytes < lengthBytes }
}

struct BootReport {
    var status: String
    var reason: String?
    var workingCopy: String?
    var backupOffset: Int64?
    var sector: NTFSBootSector?
}

struct VolumeReport {
    var status: String
    var info: NTFSVolumeInfo?
    var reason: String?
}

struct ListingReport {
    var status: String
    var rootEntries: Int?
    var recursiveEntries: Int?
    var directories: Int?
    var truncated = false
    var note: String?
}

struct DamageReport {
    var status: String
    var mapfile: String?
    /// Failed (`*`, `/`) plus bad (`-`): all are unreadable so far.
    var unreadableExtents: Int?
    var unreadableBytes: Int64?
    /// `*` and `/`: read errors seen, not yet trimmed or scraped.
    var failedExtents: Int?
    var failedBytes: Int64?
    /// `-`: ddrescue confirmed these.
    var badExtents: Int?
    var badBytes: Int64?
    var remainingBytes: Int64?
    /// `?`, `*` and `/` bytes: not read, so their damage is unknown. Bad (`-`)
    /// bytes are a known extent and are not included here.
    var nonRescuedBytes: Int64?
    var limitBytes: Int64?
    var note: String?
    /// The `-` extents themselves (image bytes), which `copy` converts to
    /// volume clusters. `inspect` only reports their count and size.
    var badRanges: [MapfileExtent] = []
}

/// The same mapfile parse, worded for the command reading it.
enum DamageAudience {
    case inspect
    case copy
}

struct InspectReport {
    var status: InspectStatus
    var exitCode: Int32
    let image: String
    let asJSON: Bool
    var message: String?
    var layout: LayoutReport?
    var filesystem: FileSystemKind = .unknown
    var toolPaths: (info: String, ls: String)?
    var boot = BootReport(status: "not-checked")
    var volume = VolumeReport(status: "skipped")
    var listing = ListingReport(status: "skipped")
    var damage = DamageReport(status: "unsupported")
    var notes: [String] = []
    /// Set only for a native attach (APFS/HFS+/exFAT/FAT): the exact disk this
    /// run attached and the volumes it reported. `nil` for the NTFS path.
    var attachment: NativeAttachSummary?
    var nativeVolumes: [NativeVolumeReport] = []
    var mountPointRemoved = true
}

enum DetectedLayout {
    case volume(LayoutReport, FileSystemKind)
    case unsupported(filesystem: FileSystemKind, partition: Int?, message: String)
    case failure(String)
}

// MARK: - Inspection

private func inspect(image: String, options: InspectOptions, dependencies: InspectDependencies) -> CLIResult {
    let fs = dependencies.fileSystem
    var report = InspectReport(status: .ok, exitCode: 0, image: image, asJSON: options.asJSON)

    func fail(_ status: InspectStatus, _ code: Int32, _ message: String) -> CLIResult {
        report.status = status
        report.exitCode = code
        report.message = message
        return finish(report, options: options)
    }

    guard fs.exists(image) else {
        return fail(.toolError, 30, "no such image: \(image)")
    }
    guard fs.isRegularFile(image) else {
        return fail(.toolError, 30, "\(image) is not a regular file; inspect takes an image file")
    }

    let imageSize: Int64
    do {
        imageSize = try fs.size(image)
    } catch {
        return fail(.toolError, 30, "cannot read the size of \(image): \(describe(error))")
    }
    guard imageSize > 0 else {
        return fail(.toolError, 30, "\(image) is empty; there is no volume to inspect")
    }

    let detected: DetectedLayout
    do {
        detected = try detectLayout(image: image, size: imageSize, fs: fs)
    } catch {
        return fail(.toolError, 30, "cannot read \(image): \(describe(error))")
    }

    switch detected {
    case .failure(let message):
        return fail(.toolError, 30, message)
    case .unsupported(let filesystem, let partition, let message):
        report.filesystem = filesystem
        return fail(.unsupported, 30, message + (partition.map { " (partition \($0))" } ?? ""))
    case .volume(let layout, let detectedFilesystem):
        report.filesystem = detectedFilesystem
        // A native filesystem is attached read-only (docs/adr/0025); NTFS and
        // an unknown boot sector stay on the ntfs-3g userspace path below.
        if let nativeFilesystem = NativeFilesystem(kind: detectedFilesystem) {
            report.layout = layout
            return inspectNative(
                image: image,
                layout: layout,
                filesystem: nativeFilesystem,
                options: options,
                dependencies: dependencies,
                report: &report
            )
        }
        // A recognised non-NTFS filesystem is named and refused without asking
        // for the NTFS tools. "unknown" is kept as a candidate: an NTFS boot
        // sector can be missing (the MiNaH case), and the validation below is
        // what decides whether it is damaged or simply not NTFS.
        guard detectedFilesystem == .ntfs || detectedFilesystem == .unknown else {
            return fail(.unsupported, 30, unsupportedMessage(detectedFilesystem))
        }
        report.layout = layout

        // The tools are resolved only once the layout says this is NTFS: a
        // non-NTFS image is named as unsupported even on a tool-less host.
        let resolution = resolveTools(dependencies)
        report.toolPaths = resolution.paths
        guard let tools = resolution.tools else {
            return fail(
                .toolError,
                30,
                "the ntfs-3g tools were not found: set DISKTRIAGE_NTFS_PREFIX to a built "
                    + "prefix (with bin/ntfsinfo and bin/ntfsls) or add them to PATH. "
                    + "A Homebrew install keeps them in "
                    + "\(installedNTFSLocation(executablePath: dependencies.executablePath))/bin; "
                    + "check that directory or reinstall. "
                    + "inspect never falls back to mounting the image."
            )
        }

        // The primary boot sector is read before any tool, so an invalid one is
        // reported even when the tools' own message is only "Invalid argument".
        let primary: Data
        do {
            primary = try fs.read(image, offset: layout.offsetBytes, count: 512)
        } catch {
            return fail(.toolError, 30, "cannot read the boot sector at byte \(layout.offsetBytes): \(describe(error))")
        }
        let validation = NTFSBootSectorRules.validate(primary)
        var sourceForTools = image

        switch validation {
        case .valid(let boot):
            report.filesystem = .ntfs
            report.boot = BootReport(status: "ok", reason: nil, sector: boot)
            if options.restoreBootSector {
                report.notes.append(
                    "the primary boot sector is valid (\(boot.bytesPerSector) B/sector, "
                        + "\(boot.clusterSize) B/cluster); no restore was written"
                )
            }
        case .invalid(let reason):
            report.boot = BootReport(status: "invalid", reason: reason)
            if options.restoreBootSector, let workingCopy = options.workingCopy {
                // Every write below targets the copy; the original is only read.
                let backupOffset = NTFSBootSectorRules.backupOffset(
                    partitionOffset: layout.offsetBytes,
                    partitionLengthBytes: layout.lengthBytes
                )
                report.boot.backupOffset = backupOffset

                if let backupOffset {
                    if backupOffset + 512 > imageSize {
                        report.boot.status = "restore-unavailable"
                        report.boot.reason = "the backup boot sector at byte \(backupOffset) is beyond "
                            + "the \(imageSize)-byte image"
                    } else if fs.exists(workingCopy) {
                        return fail(.toolError, 30, "the working copy \(workingCopy) already exists; "
                            + "refusing to overwrite it")
                    } else {
                        do {
                            try fs.copy(from: image, to: workingCopy)
                            report.boot.workingCopy = workingCopy
                            let backup = try fs.read(workingCopy, offset: backupOffset, count: 512)
                            switch NTFSBootSectorRules.validate(backup) {
                            case .invalid(let backupReason):
                                report.boot.status = "restore-unavailable"
                                report.boot.reason = "the backup boot sector at byte \(backupOffset) "
                                    + "is invalid: \(backupReason)"
                            case .valid:
                                try fs.write(backup, to: workingCopy, offset: layout.offsetBytes)
                                report.filesystem = .ntfs
                                report.boot.status = "restored"
                                report.boot.reason = "the backup boot sector at byte \(backupOffset) "
                                    + "was copied over the primary on \(workingCopy)"
                                sourceForTools = workingCopy
                            }
                        } catch {
                            report.boot.status = "restore-unavailable"
                            report.boot.reason = "cannot make the working copy: \(describe(error))"
                        }
                    }
                } else {
                    report.boot.status = "restore-unavailable"
                    report.boot.reason = "the partition is shorter than one sector; "
                        + "there is no backup boot sector to read"
                }
            } else {
                report.notes.append(
                    "the primary boot sector is invalid; to restore it, pass "
                        + "--restore-boot-sector --to <working-copy>. The original image is never written."
                )
            }
        }

        // ntfs-3g has no offset option, so a whole-disk image is extracted to a
        // temporary working file (the spike's least-bad route) and the tools run
        // on that. Cluster numbers are volume-relative because of this.
        var temporary: String?
        if layout.isWholeDisk {
            let toolImage = fs.temporaryFile()
            do {
                let written = try fs.extract(
                    from: sourceForTools,
                    offset: layout.offsetBytes,
                    length: layout.availableBytes,
                    to: toolImage
                )
                guard written > 0 else {
                    return fail(.toolError, 30, "the NTFS partition at byte \(layout.offsetBytes) "
                        + "is empty or beyond the image")
                }
                temporary = toolImage
                sourceForTools = toolImage
            } catch {
                return fail(.toolError, 30, "cannot extract the NTFS partition: \(describe(error))")
            }
        }
        defer {
            if let temporary { fs.remove(temporary) }
        }

        // Volume information. The tool's exit code decides "opened"; stderr on a
        // zero exit is partial success, not a complete answer.
        let volumeResult = tools.volumeInfo(image: sourceForTools)
        switch volumeResult.outcome {
        case .ok:
            report.volume.info = NTFSVolumeInfoParser.parse(volumeResult.stdout)
            let stderr = trimmed(volumeResult.stderr)
            if report.volume.info == nil {
                report.volume.status = "partial"
                report.volume.reason = "ntfsinfo exited 0 but its volume record was not understood"
            } else if !stderr.isEmpty || volumeResult.stdoutTruncated {
                report.volume.status = "partial"
                report.volume.reason = stderr.isEmpty
                    ? "ntfsinfo output was truncated"
                    : firstLine(stderr)
            } else {
                report.volume.status = "ok"
            }
        case .timeout:
            report.volume.status = "timeout"
            report.volume.reason = "ntfsinfo did not answer within its hard timeout"
        case .denied:
            report.volume.status = "error"
            report.volume.reason = "ntfsinfo was denied: "
                + (firstLine(trimmed(volumeResult.stderr)) ?? "no message")
        case .notFound:
            report.volume.status = "error"
            report.volume.reason = "ntfsinfo disappeared before exec"
        case .policyRejected:
            report.volume.status = "error"
            report.volume.reason = policyRejection(
                tool: "ntfsinfo",
                image: sourceForTools,
                result: volumeResult
            )
        case .error:
            report.volume.status = "error"
            report.volume.reason = firstLine(trimmed(volumeResult.stderr))
                ?? "ntfsinfo exited \(volumeResult.exitCode.map(String.init) ?? "on a signal")"
        }

        // A restored boot sector is proven by the re-open below; if it still
        // fails, the damage is beyond the boot sector and the report stays
        // volume-level.

        guard report.volume.status == "ok" || report.volume.status == "partial" else {
            let code: Int32 = 30
            let message: String
            if report.volume.status == "timeout" {
                message = "the volume did not open: \(report.volume.reason ?? "ntfsinfo timed out")"
            } else if report.boot.status == "invalid" {
                message = "the volume cannot be opened: the primary boot sector is invalid "
                    + "(\(report.boot.reason ?? "unknown reason")); \(report.volume.reason ?? "ntfsinfo failed")"
            } else if report.boot.status == "restore-unavailable" {
                message = "the volume cannot be opened: \(report.boot.reason ?? "restore failed"); "
                    + (report.volume.reason ?? "ntfsinfo failed")
            } else {
                message = "the volume cannot be opened: \(report.volume.reason ?? "ntfsinfo failed")"
            }
            report.status = .toolError
            report.exitCode = code
            report.message = message
            report.damage = readDamage(image: image, mapfile: options.mapfile, fs: fs)
            return finish(report, options: options)
        }

        // Listings. The root long listing carries sizes; the recursive one
        // carries the tree. Both are capped and both are evidence only when the
        // tool's own stderr is clean.
        let rootResult = tools.listing(image: sourceForTools, recursive: false)
        let recursiveResult = tools.listing(image: sourceForTools, recursive: true)
        var states: [String] = []
        var notes: [String] = []
        for (result, title) in [(rootResult, "ntfsls -l"), (recursiveResult, "ntfsls -R")] {
            switch result.outcome {
            case .ok:
                let stderr = trimmed(result.stderr)
                if result.stdoutTruncated {
                    states.append("partial")
                    notes.append("\(title) output was truncated at the process cap")
                } else if !stderr.isEmpty {
                    states.append("partial")
                    notes.append(shortNote(stderr))
                } else {
                    states.append("ok")
                }
            case .timeout:
                states.append("timeout")
                notes.append("\(title) did not answer within its hard timeout")
            case .policyRejected:
                states.append("error")
                notes.append(policyRejection(tool: title, image: sourceForTools, result: result))
            case .denied, .notFound, .error:
                states.append("error")
                notes.append(firstLine(trimmed(result.stderr))
                    ?? "\(title) exited \(result.exitCode.map(String.init) ?? "on a signal")")
            }
        }

        let rootListing = rootResult.outcome == .ok ? NTFSListingParser.parse(rootResult.stdout) : nil
        let recursiveListing = recursiveResult.outcome == .ok ? NTFSListingParser.parse(recursiveResult.stdout) : nil
        report.listing.rootEntries = rootListing?.entries.count
        report.listing.recursiveEntries = recursiveListing?.entries.count
        report.listing.directories = recursiveListing?.directoryCount
        report.listing.truncated = (rootListing?.truncated ?? false)
            || (recursiveListing?.truncated ?? false)
            || rootResult.stdoutTruncated
            || recursiveResult.stdoutTruncated
        if report.listing.truncated {
            states.append("partial")
            notes.append("the listing reached the entry cap (a capped listing is not a complete answer)")
        }
        let note = Array(Set(notes)).sorted().joined(separator: "; ")
        report.listing.note = note.isEmpty ? nil : note

        if states.contains("timeout") {
            report.listing.status = "timeout"
        } else if states.contains("error") {
            report.listing.status = "error"
        } else if states.contains("partial") {
            report.listing.status = "partial"
        } else {
            report.listing.status = "ok"
        }

        report.damage = readDamage(image: image, mapfile: options.mapfile, fs: fs)

        // Exit-code precedence inside inspect: a tool error (30) outranks the
        // partial/damage note (1), and any damage note outranks a clean 0.
        var code: Int32 = 0
        var status = InspectStatus.ok
        if report.listing.status == "timeout" || report.listing.status == "error"
            || report.damage.status == "error" {
            code = 30
            status = .toolError
            if report.listing.status == "timeout" {
                report.message = "the listing timed out: \(report.listing.note ?? "no message")"
            } else if report.listing.status == "error" {
                report.message = "the listing failed: \(report.listing.note ?? "no message")"
            } else {
                report.message = report.damage.note ?? "the mapfile could not be read"
            }
        } else {
            if report.listing.status == "error" || report.listing.status == "partial"
                || report.volume.status == "partial" || report.listing.truncated {
                code = 1
                status = .partial
            }
            if let extents = report.damage.unreadableExtents, extents > 0 {
                code = 1
                status = .damage
            } else if report.damage.status == "ok", (report.damage.remainingBytes ?? 0) > 0 {
                code = 1
                status = .damage
            }
        }
        report.status = status
        report.exitCode = code
        return finish(report, options: options)
    }
}

// MARK: - Layout

func detectLayout(image: String, size: Int64, fs: any InspectFileSystem) throws -> DetectedLayout {
    let prefix = try fs.read(image, offset: 0, count: Int(min(2048, size)))
    let prefixKind = FileSystemDetector.detect(prefix)
    if prefixKind != .unknown {
        // A recognised volume boot sector at byte 0 is a bare volume. This
        // check comes before the MBR parse because a FAT/exFAT boot sector also
        // carries `55 AA` at offset 510 and would otherwise look like a table.
        return .volume(LayoutReport(
            kind: "bare-volume",
            scheme: nil,
            partition: nil,
            offsetBytes: 0,
            lengthBytes: size,
            availableBytes: size,
            extracted: false
        ), prefixKind)
    }

    let sector0 = try fs.read(image, offset: 0, count: 512)
    guard let mbr = PartitionTableParser.parseMBR(sector0), !mbr.partitions.isEmpty else {
        // No table: a bare volume. The detected kind may be "unknown" when the
        // boot sector is damaged; the boot-sector validation is what decides
        // whether that is an NTFS volume to report or restore.
        return .volume(LayoutReport(
            kind: "bare-volume",
            scheme: nil,
            partition: nil,
            offsetBytes: 0,
            lengthBytes: size,
            availableBytes: size,
            extracted: false
        ), prefixKind)
    }

    var table = mbr
    if mbr.isProtective {
        let sector1 = try fs.read(image, offset: 512, count: 512)
        guard let header = PartitionTableParser.parseGPTHeader(sector1) else {
            return .failure("the GPT header at LBA 1 is unreadable or malformed; "
                + "the whole-disk image has no usable partition table")
        }
        let entries = try fs.read(image, offset: header.entryOffset, count: header.entryBytes)
        guard let gpt = PartitionTableParser.parseGPTEntries(header, entries: entries) else {
            return .failure("the GPT entry array at byte \(header.entryOffset) is unreadable; "
                + "the whole-disk image has no usable partition table")
        }
        table = gpt
    }

    // NTFS candidates first, then every other entry only to name a filesystem
    // when no NTFS partition exists.
    var ordered: [DiskPartition] = []
    var seen: Set<Int> = []
    for partition in table.ntfsCandidates + table.partitions where seen.insert(partition.index).inserted {
        ordered.append(partition)
    }

    var firstKnown: (FileSystemKind, DiskPartition)?
    var unknownNTFSCandidate: (DiskPartition, Int64, Int64)?
    for partition in ordered {
        let offset = partition.byteOffset
        guard offset >= 0, offset < size else { continue }
        let available = min(partition.byteLength, size - offset)
        guard available > 0 else { continue }
        let prefix = try fs.read(image, offset: offset, count: Int(min(2048, available)))
        let kind = FileSystemDetector.detect(prefix)
        if kind == .ntfs {
            return .volume(LayoutReport(
                kind: "whole-disk",
                scheme: table.scheme,
                partition: partition.index,
                offsetBytes: offset,
                lengthBytes: partition.byteLength,
                availableBytes: available,
                extracted: true
            ), .ntfs)
        }
        if kind == .unknown, table.ntfsCandidates.contains(partition), unknownNTFSCandidate == nil {
            // The table says NTFS but the boot sector is missing (the MiNaH
            // case). Keep it as a candidate so the boot-sector/restore path can
            // report or repair it, instead of looking like an unknown disk.
            unknownNTFSCandidate = (partition, offset, available)
        }
        if kind != .unknown, firstKnown == nil {
            firstKnown = (kind, partition)
        }
    }

    if let (partition, offset, available) = unknownNTFSCandidate {
        return .volume(LayoutReport(
            kind: "whole-disk",
            scheme: table.scheme,
            partition: partition.index,
            offsetBytes: offset,
            lengthBytes: partition.byteLength,
            availableBytes: available,
            extracted: true
        ), .unknown)
    }
    if let (kind, partition) = firstKnown {
        // A native filesystem is a volume the caller attaches read-only. The
        // layout is the partition it was found in, so the report keeps the
        // byte offset and length the mapfile conversion needs.
        if NativeFilesystem(kind: kind) != nil {
            let offset = partition.byteOffset
            let available = min(partition.byteLength, size - offset)
            return .volume(LayoutReport(
                kind: "whole-disk",
                scheme: table.scheme,
                partition: partition.index,
                offsetBytes: offset,
                lengthBytes: partition.byteLength,
                availableBytes: available,
                extracted: false
            ), kind)
        }
        return .unsupported(
            filesystem: kind,
            partition: partition.index,
            message: unsupportedMessage(kind)
        )
    }
    return .failure("no NTFS partition and no recognised filesystem in the image's partition table")
}

func unsupportedMessage(_ kind: FileSystemKind) -> String {
    if kind == .unknown {
        return "unrecognised filesystem: native read-only attach not implemented yet"
    }
    return "filesystem \(kind.rawValue): native read-only attach not implemented yet"
}

// MARK: - Tools

private func resolveTools(
    _ dependencies: InspectDependencies
) -> (tools: (any NTFSToolRunning)?, paths: (info: String, ls: String)?) {
    if let injected = dependencies.tools {
        if let runner = injected as? NTFSToolRunner {
            return (injected, (runner.toolchain.ntfsinfo, runner.toolchain.ntfsls))
        }
        return (injected, nil)
    }
    guard dependencies.resolveTools,
          let chain = NTFSToolLocator.locate(
              environment: dependencies.environment,
              executablePath: dependencies.executablePath
          ),
          let live = NTFSToolRunner.live(
              environment: dependencies.environment,
              executablePath: dependencies.executablePath
          )
    else {
        return (nil, nil)
    }
    return (live, (chain.ntfsinfo, chain.ntfsls))
}

/// The location the Homebrew formula installs into, or a placeholder when the
/// executable path is unknown. The missing-tools message names it explicitly:
/// the old "not found" left a user with a keg-private tree no search path
/// covered.
func installedNTFSLocation(executablePath: String?) -> String {
    NTFSToolLocator.installedPrefix(executablePath: executablePath)
        ?? "<install prefix>/libexec/ntfs-3g"
}

/// A policy rejection is never a mystery: the message names the tool, the
/// argument that was rejected and the violation. The policy itself stays
/// absolute-only; this only makes its refusal legible.
private func policyRejection(tool: String, image: String, result: CollectorResult) -> String {
    let violation = result.policyViolation?.rawValue ?? PolicyViolation.notAllowListed.rawValue
    return "the \(tool) command was rejected by the command policy: "
        + "argument '\(image)' is not allow-listed (\(violation))"
}

// MARK: - Mapfile

struct InspectSidecar: Decodable {
    let limitBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case limitBytes = "limit_bytes"
    }
}

func sidecarLimit(image: String, fs: any InspectFileSystem) -> Int64? {
    let path = image + ".disktriage.json"
    guard fs.exists(path),
          let size = try? fs.size(path),
          size > 0,
          size <= 65_536,
          let data = try? fs.read(path, offset: 0, count: Int(size))
    else { return nil }
    return (try? JSONDecoder().decode(InspectSidecar.self, from: data))?.limitBytes
}

func readDamage(
    image: String,
    mapfile: String?,
    fs: any InspectFileSystem,
    audience: DamageAudience = .inspect
) -> DamageReport {
    let defaultMapfile = image + ".mapfile"
    let path = mapfile ?? (fs.exists(defaultMapfile) ? defaultMapfile : nil)
    guard let path else {
        var report = DamageReport(status: "unsupported")
        report.note = "absent is never a zero: supply --mapfile or place <image>.mapfile "
            + "beside the image"
        return report
    }

    var report = DamageReport(status: "error", mapfile: path)
    let limit = sidecarLimit(image: image, fs: fs)
    report.limitBytes = limit

    do {
        let size = try fs.size(path)
        guard size > 0, size <= 8_388_608 else {
            report.note = "\(path) is empty or larger than 8 MiB; it is not a usable mapfile"
            return report
        }
        let text = String(decoding: try fs.read(path, offset: 0, count: Int(size)), as: UTF8.self)
        guard let snapshot = DdrescueMapfile.parse(text, limitBytes: limit) else {
            report.note = "\(path) is not a GNU ddrescue mapfile"
            return report
        }

        let failed = snapshot.failedExtents
        let bad = snapshot.badExtents
        report.status = "ok"
        // `*` and `/` contain read errors too, so they are unreadable so far.
        // Only `-` is confirmed; the distinction is kept in the fields below.
        report.failedExtents = failed.count
        report.failedBytes = snapshot.failedBytes
        report.badExtents = bad.count
        report.badBytes = snapshot.badBytes
        report.unreadableExtents = failed.count + bad.count
        report.unreadableBytes = snapshot.failedBytes + snapshot.badBytes
        report.remainingBytes = snapshot.remainingBytes
        report.nonRescuedBytes = snapshot.nonTriedBytes
            + snapshot.nonTrimmedBytes
            + snapshot.nonScrapedBytes
        report.badRanges = bad

        var notes: [String] = []
        switch audience {
        case .inspect:
            notes.append(
                "unreadable regions are zero-filled in the image; a listing that exits 0 is not proof "
                    + "of intact data; per-file attribution is a copy feature and is not claimed here"
            )
        case .copy:
            notes.append(
                "unreadable regions are zero-filled in the image, so a copy of them hashes perfectly; "
                    + "hash equality proves the copy matches the IMAGE, not the platter"
            )
        }
        if failed.isEmpty && bad.isEmpty {
            if snapshot.isComplete {
                notes.append("no unreadable extent is recorded in the mapfile")
            } else {
                notes.append(
                    "the mapfile is not complete: \(snapshot.remainingBytes) bytes were not rescued; "
                        + "the damage extent is unknown"
                )
            }
        } else if !snapshot.isComplete && !failed.isEmpty {
            notes.append(
                "the mapfile is incomplete: failed extents may shrink after trimming and scraping; "
                    + "\(snapshot.remainingBytes) bytes were not rescued"
            )
        }
        report.note = notes.joined(separator: "; ")
    } catch {
        report.status = "error"
        report.note = "cannot read the mapfile \(path): \(describe(error))"
    }
    return report
}

// MARK: - Rendering

func finish(_ report: InspectReport, options: InspectOptions) -> CLIResult {
    let stdout: String
    let stderr: String

    if options.asJSON {
        stdout = renderJSON(report)
        stderr = ""
    } else if report.layout == nil {
        stdout = ""
        stderr = "disktriage: \(report.message ?? report.status.rawValue)\n"
    } else {
        stdout = renderTTY(report)
        stderr = report.exitCode == 30
            ? "disktriage: \(report.message ?? "the inspection stopped")\n"
            : ""
    }

    return CLIResult(stdout: stdout, stderr: stderr, exitCode: report.exitCode)
}

private func renderTTY(_ report: InspectReport) -> String {
    var lines: [String] = []
    lines.append(pad("IMAGE", 11) + report.image)

    if let layout = report.layout {
        var text = layout.kind
        if let scheme = layout.scheme { text += " (\(scheme.rawValue))" }
        if let partition = layout.partition { text += " · partition \(partition)" }
        text += " · byte \(layout.offsetBytes), \(layout.lengthBytes) bytes"
        if layout.extracted { text += " · extracted for the tools" }
        if layout.partial {
            text += " · the image is shorter than the partition "
                + "(\(layout.availableBytes) of \(layout.lengthBytes) bytes available)"
        }
        lines.append(pad("LAYOUT", 11) + text)
    }

    lines.append(pad("FILESYSTEM", 11) + report.filesystem.rawValue.uppercased())
    if let paths = report.toolPaths {
        lines.append(pad("TOOLS", 11) + "ntfsinfo \(paths.info) · ntfsls \(paths.ls)")
    }
    if let attachment = report.attachment {
        lines.append(pad("ATTACH", 11) + "read-only · diskutil image attach --noMount "
            + "--readOnly · \(attachment.wholeDisk)")
        for volume in report.nativeVolumes {
            var text = "\(volume.index) · \(volume.displayName) · \(volume.device) · "
                + volume.filesystem.displayName + " · " + volume.status
            if let root = volume.rootEntries { text += " · \(root) root entries" }
            if let recursive = volume.recursiveEntries { text += " · \(recursive) entries" }
            if volume.locked { text += " · encrypted, locked, not mounted" }
            if let reason = volume.reason { text += " · \(reason)" }
            lines.append(pad("VOLUME", 11) + text)
        }
    }

    if report.attachment == nil {
        switch report.boot.status {
        case "ok":
            if let sector = report.boot.sector {
                lines.append(pad("BOOT", 11) + "ok · \(sector.oemID) · "
                    + "\(sector.bytesPerSector) B/sector · \(sector.clusterSize) B/cluster")
            } else {
                lines.append(pad("BOOT", 11) + "ok")
            }
        case "invalid":
            lines.append(pad("BOOT", 11) + "invalid · \(report.boot.reason ?? "unknown reason")")
        case "restored":
            lines.append(pad("BOOT", 11) + "restored on the working copy "
                + (report.boot.workingCopy ?? "?")
                + (report.boot.backupOffset.map { " (backup at byte \($0))" } ?? ""))
        case "restore-unavailable":
            lines.append(pad("BOOT", 11) + "cannot restore · \(report.boot.reason ?? "unknown reason")")
        default:
            lines.append(pad("BOOT", 11) + report.boot.status)
        }
    
        switch report.volume.status {
        case "ok", "partial":
            var text = report.volume.status
            if let info = report.volume.info {
                text += " · " + volumeDetail(info)
            }
            if let reason = report.volume.reason { text += " · " + reason }
            lines.append(pad("VOLUME", 11) + text)
        case "skipped":
            lines.append(pad("VOLUME", 11) + "not opened")
        default:
            lines.append(pad("VOLUME", 11) + "cannot open · \(report.volume.reason ?? "unknown reason")")
        }
    }

    switch report.listing.status {
    case "ok", "partial":
        var text = report.listing.status
        if let root = report.listing.rootEntries { text += " · \(root) root entries" }
        if let recursive = report.listing.recursiveEntries { text += " · \(recursive) recursive entries" }
        if report.listing.truncated { text += " · capped" }
        if let note = report.listing.note { text += " · \(note)" }
        lines.append(pad("LISTING", 11) + text)
    case "skipped":
        lines.append(pad("LISTING", 11) + "skipped: the volume did not open")
    default:
        lines.append(pad("LISTING", 11) + "\(report.listing.status)"
            + (report.listing.note.map { " · \($0)" } ?? ""))
    }

    if report.damage.status == "ok" {
        let extents = report.damage.unreadableExtents ?? 0
        let bytes = report.damage.unreadableBytes ?? 0
        let failed = report.damage.failedExtents ?? 0
        let confirmed = report.damage.badExtents ?? 0
        lines.append(pad("DAMAGE", 11)
            + "mapfile \(report.damage.mapfile ?? "?") · \(extents) unreadable "
            + "\(extents == 1 ? "extent" : "extents") · \(bytes) bytes "
            + "(\(failed) failed, \(confirmed) confirmed bad)")
        if let note = report.damage.note {
            lines.append(pad("", 11) + note)
        }
    } else if report.damage.status == "unsupported" {
        lines.append(pad("DAMAGE", 11) + "damage unknown (no mapfile)")
        if let note = report.damage.note {
            lines.append(pad("", 11) + note)
        }
    } else {
        lines.append(pad("DAMAGE", 11) + "error · \(report.damage.note ?? "the mapfile could not be read")")
    }

    for note in report.notes {
        lines.append(pad("NOTE", 11) + note)
    }

    let result: String
    switch report.status {
    case .ok:
        if report.damage.status == "unsupported" {
            result = "inspected; damage UNKNOWN (no mapfile supplied)"
        } else {
            result = "inspected; no damage note"
        }
    case .damage:
        result = "inspected; mapfile reports damage"
    case .partial:
        result = "inspected; the volume only partially opened"
    case .unsupported:
        result = "tool error (exit 30): \(report.message ?? "unsupported filesystem")"
    case .toolError:
        result = "tool error (exit 30): \(report.message ?? "the inspection stopped")"
    }
    lines.append("")
    lines.append(pad("RESULT", 11) + result)
    return lines.joined(separator: "\n") + "\n"
}

private func renderJSON(_ report: InspectReport) -> String {
    var object: [String: Any] = [
        "command": "inspect",
        "status": report.status.rawValue,
        "exit_code": Int(report.exitCode),
        "image": report.image,
        "filesystem": report.filesystem.rawValue,
        "notes": report.notes,
    ]
    if let message = report.message { object["message"] = message }
    if let paths = report.toolPaths {
        object["tools"] = ["ntfsinfo": paths.info, "ntfsls": paths.ls]
    } else {
        object["tools"] = NSNull()
    }

    if let attachment = report.attachment {
        object["attach"] = [
            "mode": "read-only",
            "whole_disk": attachment.wholeDisk,
            "no_mount": true,
            "volumes": attachment.volumes.map { volume in
                [
                    "index": volume.index,
                    "device": volume.device,
                    "name": volume.name ?? NSNull(),
                    "filesystem": volume.filesystem.rawValue,
                    "encrypted": volume.encrypted,
                    "locked": volume.locked,
                ] as [String: Any]
            },
        ]
        object["volumes"] = report.nativeVolumes.map { volume in
            var value: [String: Any] = [
                "index": volume.index,
                "device": volume.device,
                "filesystem": volume.filesystem.rawValue,
                "encrypted": volume.encrypted,
                "locked": volume.locked,
                "status": volume.status,
                "truncated": volume.truncated,
            ]
            value["name"] = volume.name ?? NSNull()
            value["reason"] = volume.reason ?? NSNull()
            value["root_entries"] = volume.rootEntries.map { $0 } ?? NSNull()
            value["recursive_entries"] = volume.recursiveEntries.map { $0 } ?? NSNull()
            value["directories"] = volume.directories.map { $0 } ?? NSNull()
            return value
        }
    }

    if let layout = report.layout {
        var value: [String: Any] = [
            "kind": layout.kind,
            "offset_bytes": layout.offsetBytes,
            "length_bytes": layout.lengthBytes,
            "available_bytes": layout.availableBytes,
            "partial": layout.partial,
            "extracted": layout.extracted,
        ]
        value["scheme"] = layout.scheme?.rawValue ?? NSNull()
        value["partition"] = layout.partition.map { $0 } ?? NSNull()
        object["layout"] = value
    }

    var boot: [String: Any] = ["status": report.boot.status]
    if let reason = report.boot.reason { boot["reason"] = reason }
    if let workingCopy = report.boot.workingCopy { boot["working_copy"] = workingCopy }
    if let offset = report.boot.backupOffset { boot["backup_offset_bytes"] = offset }
    if let sector = report.boot.sector {
        boot["bytes_per_sector"] = sector.bytesPerSector
        boot["sectors_per_cluster"] = sector.sectorsPerCluster
    }
    object["boot_sector"] = boot

    var volume: [String: Any] = ["status": report.volume.status]
    if let info = report.volume.info {
        volume["name"] = info.volumeName ?? NSNull()
        volume["version"] = info.volumeVersion ?? NSNull()
        volume["flags"] = info.volumeFlags ?? NSNull()
        volume["sector_size"] = info.sectorSize.map { $0 } ?? NSNull()
        volume["cluster_size"] = info.clusterSize.map { $0 } ?? NSNull()
        volume["index_block_size"] = info.indexBlockSize.map { $0 } ?? NSNull()
        volume["clusters"] = info.volumeSizeClusters.map { $0 } ?? NSNull()
        volume["free_clusters"] = info.freeClusters.map { $0 } ?? NSNull()
    }
    if let reason = report.volume.reason { volume["reason"] = reason }
    object["volume"] = volume

    var listing: [String: Any] = [
        "status": report.listing.status,
        "truncated": report.listing.truncated,
    ]
    if let root = report.listing.rootEntries { listing["root_entries"] = root }
    if let recursive = report.listing.recursiveEntries { listing["recursive_entries"] = recursive }
    if let directories = report.listing.directories { listing["directories"] = directories }
    if let note = report.listing.note { listing["note"] = note }
    object["listing"] = listing

    var damage: [String: Any] = ["status": report.damage.status]
    if let mapfile = report.damage.mapfile { damage["mapfile"] = mapfile }
    if let extents = report.damage.unreadableExtents { damage["unreadable_extents"] = extents }
    if let bytes = report.damage.unreadableBytes { damage["unreadable_bytes"] = bytes }
    if let extents = report.damage.failedExtents { damage["failed_extents"] = extents }
    if let bytes = report.damage.failedBytes { damage["failed_bytes"] = bytes }
    if let extents = report.damage.badExtents { damage["bad_extents"] = extents }
    if let bytes = report.damage.badBytes { damage["bad_bytes"] = bytes }
    if let remaining = report.damage.remainingBytes { damage["remaining_bytes"] = remaining }
    if let limit = report.damage.limitBytes { damage["limit_bytes"] = limit }
    if report.damage.status == "ok" {
        damage["scope"] = "volume"
        damage["attribution"] = "none"
        damage["zero_filled"] = true
    }
    if let note = report.damage.note { damage["note"] = note }
    object["damage"] = damage

    guard let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let text = String(data: data, encoding: .utf8) else {
        return "{}\n"
    }
    return text + "\n"
}

// MARK: - Formatting

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}

private func volumeDetail(_ info: NTFSVolumeInfo) -> String {
    var parts: [String] = []
    if let name = info.volumeName { parts.append(name) }
    if let version = info.volumeVersion { parts.append("version \(version)") }
    if let sector = info.sectorSize { parts.append("\(sector) B/sector") }
    if let cluster = info.clusterSize { parts.append("\(cluster) B/cluster") }
    if let clusters = info.volumeSizeClusters { parts.append("\(clusters) clusters") }
    if let free = info.freeClusters { parts.append("\(free) free") }
    return parts.isEmpty ? "opened" : parts.joined(separator: " · ")
}

func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func firstLine(_ text: String) -> String? {
    let line = trimmed(text).split(separator: "\n").first.map(String.init)
    return line?.isEmpty == false ? line : nil
}

/// A bounded one-paragraph note from a tool's stderr: every non-empty line is
/// kept, because `ntfsls`'s meaningful line ("Corrupt index block signature")
/// is often the second one.
func shortNote(_ text: String) -> String {
    let lines = trimmed(text)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let joined = lines.joined(separator: " · ")
    return joined.count <= 400 ? joined : String(joined.prefix(400)) + "…"
}

func isDevicePath(_ path: String) -> Bool {
    path == "/dev" || path.hasPrefix("/dev/")
}

func describe(_ error: Error) -> String {
    if let inspectError = error as? InspectFileSystemError {
        return inspectError.description
    }
    return (error as NSError).localizedDescription
}

private let inspectUsage = "usage: disktriage inspect <image> [options]\n"
    + "\n"
    + "Inspects an image read-only. NTFS is read with the ntfs-3g userspace\n"
    + "tools (ntfsinfo, ntfsls), without mounting it. APFS, HFS+, exFAT and\n"
    + "FAT are attached with diskutil image attach --noMount --readOnly and\n"
    + "mounted readOnly nobrowse. The image is never written.\n"
    + "\n"
    + "  --mapfile <path>        damage notes from this ddrescue mapfile\n"
    + "                          (default: <image>.mapfile when it exists)\n"
    + "  --restore-boot-sector   copy the backup boot sector over the primary\n"
    + "  --to <working-copy>     the new copy to restore; the original is never\n"
    + "                          written (required with --restore-boot-sector)\n"
    + "  --json                  print the report as JSON\n"
    + "\n"
    + "Exit 0 inspected with no damage note, 1 inspected but the mapfile\n"
    + "reports damage or the volume only partly opened, 30 a precondition or\n"
    + "tool error. A device node (/dev/*) is refused with a usage error (2).\n"
