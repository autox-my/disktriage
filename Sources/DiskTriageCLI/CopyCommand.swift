import Foundation
import CryptoKit
import DiskTriageCore
import DiskTriageCollectors

/// The injectable side of `copy`: the filesystem (real temporary images and
/// destinations in tests) and the ntfs-3g runner (recorded output in tests).
public struct CopyDependencies: Sendable {
    public var fileSystem: any CopyFileSystem
    public var environment: [String: String]
    public var tools: (any NTFSCopyToolRunning)?
    /// `false` with `tools == nil` means "pretend the tools are not installed".
    public var resolveTools: Bool
    /// The directory a relative path argument is resolved against.
    public var currentDirectory: String
    public var now: @Sendable () -> Date

    public init(
        fileSystem: any CopyFileSystem = LiveCopyFileSystem(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tools: (any NTFSCopyToolRunning)? = nil,
        resolveTools: Bool = true,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileSystem = fileSystem
        self.environment = environment
        self.tools = tools
        self.resolveTools = resolveTools
        self.currentDirectory = currentDirectory
        self.now = now
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CopyDependencies {
        CopyDependencies(fileSystem: LiveCopyFileSystem(), environment: environment)
    }
}

/// `disktriage copy <image> --to <dir> [--mapfile <path>] [--json]
/// [--hash-image]` (diskdoctor.md §6, §8 "Copy and damage reporting").
///
/// v1 copies the NTFS file tree read-only with `ntfsls` + `ntfscat`, hashes
/// every byte it reads and writes, and reports damage at volume level. Per-file
/// integrity is claimed only when the one-pass `ntfscluster` run map is
/// available. Exit 0 copied, hashes agree and no damage; 1 copied with damage,
/// a partial copy, a hash mismatch, or no per-file attribution on a damaged
/// image; 30 a precondition/tool error.
public func runCopy(arguments: [String], dependencies: CopyDependencies? = nil) -> CLIResult {
    if arguments.contains("--help") || arguments.contains("-h") {
        return help(copyUsage)
    }

    var options = CopyOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--to":
            guard index + 1 < arguments.count else {
                return usageError("--to needs a destination directory")
            }
            options.destination = arguments[index + 1]
            index += 2
        case "--mapfile":
            guard index + 1 < arguments.count else {
                return usageError("--mapfile needs a path")
            }
            options.mapfile = arguments[index + 1]
            index += 2
        case "--hash-image":
            options.hashImage = true
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
                return usageError("copy takes one image, not '\(argument)'")
            }
            options.image = argument
            index += 1
        }
    }

    guard let rawImage = options.image else {
        return usageError("copy needs an image file (it copies images only, never /dev/*)")
    }
    guard let rawDestination = options.destination else {
        return usageError("copy needs --to <directory>")
    }

    let dependencies = dependencies ?? .live()
    let image = InspectPathRules.absolute(rawImage, currentDirectory: dependencies.currentDirectory)
    let destination = InspectPathRules.absolute(
        rawDestination,
        currentDirectory: dependencies.currentDirectory
    )
    let mapfile = options.mapfile.map {
        InspectPathRules.absolute($0, currentDirectory: dependencies.currentDirectory)
    }

    if let refusal = deviceNodeRefusal(
        argument: rawImage,
        resolved: image,
        prefix: "copy accepts an image file, not a device node",
        suffix: ". Image the device first; copy never reads /dev/*."
    ) {
        return refusal
    }
    if let refusal = deviceNodeRefusal(
        argument: rawDestination,
        resolved: destination,
        prefix: "--to must be a directory, not a device node",
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
    if destination == image {
        return usageError("--to must be a directory, not the image being copied")
    }

    options.image = image
    options.destination = destination
    options.mapfile = mapfile
    return copy(image: image, options: options, dependencies: dependencies)
}

// MARK: - Options

private struct CopyOptions {
    var image: String?
    var destination: String?
    var mapfile: String?
    var hashImage = false
    var asJSON = false
}

// MARK: - Report

private enum CopyStatus: String {
    case ok
    case damage
    case partial
    case toolError = "tool-error"
    case unsupported
}

private struct CopyReport {
    var status: CopyStatus
    var exitCode: Int32
    let image: String
    let destination: String
    let asJSON: Bool
    var message: String?
    var layout: LayoutReport?
    var filesystem: FileSystemKind = .unknown
    var toolPaths: (info: String, ls: String, cat: String, cluster: String)?
    var damage: DamageReport?
    var attribution: CopyAttribution = .unavailable(reason: "not attempted")
    var copyStatus = "ok"
    var entries: [CopyManifestEntry] = []
    var bytesRead: Int64 = 0
    var bytesWritten: Int64 = 0
    var hashesAgree = false
    var manifestSHA256 = ""
    var manifestPath: String?
    var summaryPath: String?
    var notes: [String] = []
    var createdAt = ""
    var imageSize: Int64 = 0
    var imageSHA256: String?
}

// MARK: - Copy

private func copy(image: String, options: CopyOptions, dependencies: CopyDependencies) -> CLIResult {
    let fs = dependencies.fileSystem
    var report = CopyReport(
        status: .ok,
        exitCode: 0,
        image: image,
        destination: options.destination ?? "",
        asJSON: options.asJSON
    )

    func fail(_ status: CopyStatus, _ code: Int32, _ message: String) -> CLIResult {
        report.status = status
        report.exitCode = code
        report.message = message
        return finish(report, options: options)
    }

    guard fs.exists(image) else {
        return fail(.toolError, 30, "no such image: \(image)")
    }
    guard fs.isRegularFile(image) else {
        return fail(.toolError, 30, "\(image) is not a regular file; copy takes an image file")
    }
    let imageSize: Int64
    do {
        imageSize = try fs.size(image)
    } catch {
        return fail(.toolError, 30, "cannot read the size of \(image): \(describe(error))")
    }
    guard imageSize > 0 else {
        return fail(.toolError, 30, "\(image) is empty; there is no volume to copy")
    }
    report.imageSize = imageSize

    // The destination is checked before any tool runs: a file cannot be a
    // directory, and a device directory is never a copy target.
    let destination = options.destination ?? ""
    if fs.exists(destination), !fs.isDirectory(destination) {
        return fail(.toolError, 30, "\(destination) exists and is not a directory; copy never overwrites it")
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
        guard detectedFilesystem == .ntfs || detectedFilesystem == .unknown else {
            return fail(.unsupported, 30, unsupportedMessage(detectedFilesystem))
        }
        report.layout = layout

        let resolution = resolveCopyTools(dependencies)
        report.toolPaths = resolution.paths
        guard let tools = resolution.tools else {
            return fail(
                .toolError,
                30,
                "the ntfs-3g tools were not found: set DISKTRIAGE_NTFS_PREFIX to a built "
                    + "prefix (with bin/ntfsinfo, bin/ntfsls, bin/ntfscat and bin/ntfscluster) "
                    + "or add them to PATH. copy never falls back to mounting the image."
            )
        }

        let primary: Data
        do {
            primary = try fs.read(image, offset: layout.offsetBytes, count: 512)
        } catch {
            return fail(
                .toolError,
                30,
                "cannot read the boot sector at byte \(layout.offsetBytes): \(describe(error))"
            )
        }
        let boot: NTFSBootSector
        switch NTFSBootSectorRules.validate(primary) {
        case .valid(let sector):
            boot = sector
            report.filesystem = .ntfs
        case .invalid(let reason):
            let damage = readDamage(
                image: image,
                mapfile: options.mapfile,
                fs: fs,
                audience: .copy
            )
            report.damage = damage
            return fail(
                .toolError,
                30,
                "the volume cannot be opened: the primary boot sector is invalid (\(reason)). "
                    + "copy does not restore boot sectors; inspect --restore-boot-sector --to "
                    + "<working-copy> can, on a copy."
            )
        }

        // ntfs-3g has no offset option: a whole-disk image is extracted to a
        // temporary working file, exactly as inspect does. Cluster numbers stay
        // volume-relative, which the mapfile conversion subtracts for.
        var temporary: String?
        var sourceForTools = image
        if layout.isWholeDisk {
            let toolImage = fs.temporaryFile()
            do {
                let written = try fs.extract(
                    from: image,
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

        // The volume must open before a file list is meaningful.
        let volumeResult = tools.volumeInfo(image: sourceForTools)
        guard volumeResult.outcome == .ok else {
            let reason: String
            switch volumeResult.outcome {
            case .timeout:
                reason = "ntfsinfo did not answer within its hard timeout"
            case .denied:
                reason = "ntfsinfo was denied: " + (firstLine(trimmed(volumeResult.stderr)) ?? "no message")
            case .notFound:
                reason = "ntfsinfo disappeared before exec"
            case .policyRejected:
                reason = "the ntfsinfo command was rejected by the command policy"
            default:
                reason = firstLine(trimmed(volumeResult.stderr))
                    ?? "ntfsinfo exited \(volumeResult.exitCode.map(String.init) ?? "on a signal")"
            }
            report.damage = readDamage(
                image: image,
                mapfile: options.mapfile,
                fs: fs,
                audience: .copy
            )
            return fail(.toolError, 30, "the volume cannot be opened: \(reason)")
        }
        let volume = NTFSVolumeInfoParser.parse(volumeResult.stdout)
        let clusterSize = volume?.clusterSize ?? boot.clusterSize
        let volumeClusters = volume?.volumeSizeClusters

        // Damage is read before copying so an unparsable mapfile stops the run
        // without writing anything.
        let damage = readDamage(
            image: image,
            mapfile: options.mapfile,
            fs: fs,
            audience: .copy
        )
        report.damage = damage
        if damage.status == "error" {
            return fail(.toolError, 30, damage.note ?? "the mapfile could not be read")
        }

        // One listing carries names, sizes and directory headers.
        let listingResult = tools.listing(image: sourceForTools)
        guard listingResult.outcome == .ok else {
            let reason: String
            switch listingResult.outcome {
            case .timeout:
                reason = "ntfsls did not answer within its hard timeout"
            case .denied:
                reason = "ntfsls was denied: " + (firstLine(trimmed(listingResult.stderr)) ?? "no message")
            case .notFound:
                reason = "ntfsls disappeared before exec"
            case .policyRejected:
                reason = "the ntfsls command was rejected by the command policy"
            default:
                reason = firstLine(trimmed(listingResult.stderr))
                    ?? "ntfsls exited \(listingResult.exitCode.map(String.init) ?? "on a signal")"
            }
            return fail(.toolError, 30, "the file tree cannot be listed: \(reason)")
        }

        var listingPartial = listingResult.stdoutTruncated
            || !trimmed(listingResult.stderr).isEmpty
        if listingResult.stdoutTruncated {
            report.notes.append("the listing was truncated at the process output cap")
        }
        if let note = firstLine(trimmed(listingResult.stderr)) {
            report.notes.append("ntfsls exited 0 but said: \(note)")
        }
        let listing = NTFSListingParser.parse(
            listingResult.stdout,
            maxEntries: CopyLimits.maxEntries
        )
        if listing.truncated {
            listingPartial = true
            report.notes.append(
                "the listing reached the \(CopyLimits.maxEntries)-entry cap; this is a partial copy"
            )
        }
        let directorySet = Set(listing.directories)

        var directories: [String] = []
        for directory in listing.directories where directory != "/" {
            if let refusal = CopyPathRules.refusal(directory) {
                return fail(.toolError, 30, "refusing the directory name '\(directory)': \(refusal)")
            }
            directories.append(directory)
        }

        var files: [(path: String, listedSize: Int64?)] = []
        var seen: Set<String> = []
        for entry in listing.entries {
            let path = listing.volumePath(for: entry)
            // A directory appears both as a header and as a zero-size entry.
            guard !directorySet.contains(path) else { continue }
            guard seen.insert(path).inserted else { continue }
            if let refusal = CopyPathRules.refusal(path) {
                return fail(.toolError, 30, "refusing the file name '\(path)': \(refusal)")
            }
            files.append((path, entry.sizeBytes))
        }
        files.sort { $0.path < $1.path }

        // No-overwrite is a precondition, checked before the first write.
        if fs.exists(destination) {
            for path in files.map(\.path) {
                let target = destinationPath(destination, path)
                if fs.exists(target) {
                    return fail(
                        .toolError,
                        30,
                        "\(target) already exists; copy never overwrites a file "
                            + "(choose an empty destination directory)"
                    )
                }
            }
            for directory in directories {
                let target = destinationPath(destination, directory)
                if fs.exists(target), !fs.isDirectory(target) {
                    return fail(.toolError, 30, "\(target) exists and is not a directory; copy never overwrites it")
                }
            }
            for reserved in ["MANIFEST.json", "SUMMARY.txt"] {
                let target = destination + "/" + reserved
                if fs.exists(target) {
                    return fail(.toolError, 30, "\(target) already exists; copy never overwrites it")
                }
            }
        }

        // An explicitly requested image hash: a multi-GB image is expensive, so
        // the default is off and the manifest says why the value is null.
        if options.hashImage {
            do {
                report.imageSHA256 = try sha256File(
                    path: image,
                    size: imageSize,
                    fs: fs
                )
            } catch {
                return fail(.toolError, 30, "cannot hash \(image): \(describe(error))")
            }
        }

        // Per-file attribution is a capability, never implied.
        let badExtents = damage.badExtents.map {
            ByteRange(position: $0.position, size: $0.size)
        }
        if damage.status == "ok" {
            if let nonRescued = damage.nonRescuedBytes, nonRescued > 0 {
                report.attribution = .unavailable(
                    reason: "the mapfile is incomplete: \(nonRescued) bytes were not rescued, "
                        + "so the damage extent is unknown and no per-file integrity is claimed"
                )
            } else if let volumeClusters, volumeClusters > 0, clusterSize > 0 {
                report.attribution = attribute(
                    tools: tools,
                    image: sourceForTools,
                    volumeClusters: volumeClusters,
                    clusterSize: clusterSize,
                    partitionOffset: layout.offsetBytes,
                    badExtents: badExtents,
                    filePaths: files.map(\.path)
                )
            } else {
                report.attribution = .unavailable(
                    reason: "the volume size in clusters is unknown, so the mapfile cannot be "
                        + "converted to cluster ranges"
                )
            }
        } else {
            report.attribution = .unavailable(
                reason: "no mapfile: damage is unknown, and absent is never a zero, so no "
                    + "per-file integrity is claimed"
            )
        }

        // All preconditions hold: create directories, then copy files.
        do {
            if !fs.exists(destination) {
                try fs.createDirectory(destination)
            }
            for directory in directories {
                try fs.createDirectory(destinationPath(destination, directory))
            }
        } catch {
            return fail(.toolError, 30, "cannot create the destination tree: \(describe(error))")
        }

        let started = Date()
        var totalRead: Int64 = 0
        var totalWritten: Int64 = 0
        var failed = 0
        var allHashesAgree = true
        var entries: [CopyManifestEntry] = []
        var budgetStopped = false

        for (index, file) in files.enumerated() {
            if Date().timeIntervalSince(started) > CopyLimits.totalTimeout {
                report.notes.append(
                    "stopped after \(Int(CopyLimits.totalTimeout)) s; the remaining "
                        + "\(files.count - index) file(s) were not attempted"
                )
                budgetStopped = true
                break
            }
            if totalRead >= CopyLimits.maxTotalBytes {
                report.notes.append(
                    "stopped at the \(CopyLimits.maxTotalBytes)-byte total cap; the remaining "
                        + "\(files.count - index) file(s) were not attempted"
                )
                budgetStopped = true
                break
            }
            if let listedSize = file.listedSize, listedSize > CopyLimits.maxFileBytes {
                report.notes.append(
                    "\(file.path) is \(listedSize) bytes, above the "
                        + "\(CopyLimits.maxFileBytes)-byte per-file cap; it was not copied"
                )
                failed += 1
                allHashesAgree = false
                entries.append(CopyManifestEntry(
                    path: CopyPathRules.relative(file.path),
                    sizeBytes: listedSize,
                    sha256Read: nil,
                    sha256Written: nil,
                    integrity: nil,
                    attribution: nil,
                    status: "skipped",
                    note: "above the per-file byte cap"
                ))
                continue
            }

            let cat = tools.catFile(image: sourceForTools, path: file.path)
            guard cat.outcome == .ok else {
                let note: String
                switch cat.outcome {
                case .timeout:
                    note = "ntfscat did not answer within its hard timeout"
                case .denied:
                    note = "ntfscat was denied: " + (firstLine(trimmed(cat.stderr)) ?? "no message")
                case .notFound:
                    note = "ntfscat disappeared before exec"
                case .policyRejected:
                    note = "the ntfscat command was rejected by the command policy"
                default:
                    note = firstLine(trimmed(cat.stderr))
                        ?? "ntfscat exited \(cat.exitCode.map(String.init) ?? "on a signal")"
                }
                failed += 1
                allHashesAgree = false
                entries.append(CopyManifestEntry(
                    path: CopyPathRules.relative(file.path),
                    sizeBytes: file.listedSize,
                    sha256Read: nil,
                    sha256Written: nil,
                    integrity: nil,
                    attribution: nil,
                    status: "read-error",
                    note: note
                ))
                report.notes.append("\(file.path) was not copied: \(note)")
                continue
            }
            if cat.stdoutTruncated {
                failed += 1
                allHashesAgree = false
                entries.append(CopyManifestEntry(
                    path: CopyPathRules.relative(file.path),
                    sizeBytes: file.listedSize,
                    sha256Read: nil,
                    sha256Written: nil,
                    integrity: nil,
                    attribution: nil,
                    status: "skipped",
                    note: "ntfscat output was truncated at the process cap; a truncated file is never written"
                ))
                report.notes.append(
                    "\(file.path) was not copied: its \(cat.stdout.count) bytes are a truncated read"
                )
                continue
            }

            let data = cat.stdout
            if Int64(data.count) > CopyLimits.maxFileBytes
                || totalRead + Int64(data.count) > CopyLimits.maxTotalBytes {
                failed += 1
                allHashesAgree = false
                entries.append(CopyManifestEntry(
                    path: CopyPathRules.relative(file.path),
                    sizeBytes: Int64(data.count),
                    sha256Read: nil,
                    sha256Written: nil,
                    integrity: nil,
                    attribution: nil,
                    status: "skipped",
                    note: "above the per-file or total byte cap"
                ))
                report.notes.append("\(file.path) was not copied: it would exceed a byte cap")
                continue
            }

            let readHash = sha256Hex(data)
            let target = destinationPath(destination, file.path)
            do {
                try fs.writeFile(data, to: target)
                // Read the destination back: this proves the write landed and
                // catches a writer that corrupts bytes.
                let written = try fs.read(target, offset: 0, count: data.count)
                let writtenHash = sha256Hex(written)
                let agree = written.count == data.count && writtenHash == readHash
                allHashesAgree = allHashesAgree && agree
                totalRead += Int64(data.count)
                totalWritten += Int64(written.count)

                let integrity: CopyFileIntegrity? = report.attribution.kind == "ntfscluster"
                    ? (report.attribution.integrity[file.path] ?? .intact)
                    : nil
                entries.append(CopyManifestEntry(
                    path: CopyPathRules.relative(file.path),
                    sizeBytes: Int64(data.count),
                    sha256Read: readHash,
                    sha256Written: writtenHash,
                    integrity: integrity,
                    attribution: integrity == nil ? nil : "ntfscluster",
                    status: agree ? "ok" : "hash-mismatch",
                    note: agree ? nil : "the bytes read back differ from the bytes written"
                ))
                if !agree {
                    failed += 1
                    report.notes.append(
                        "\(file.path): written hash \(writtenHash) does not match read hash \(readHash)"
                    )
                }
            } catch {
                failed += 1
                allHashesAgree = false
                entries.append(CopyManifestEntry(
                    path: CopyPathRules.relative(file.path),
                    sizeBytes: Int64(data.count),
                    sha256Read: readHash,
                    sha256Written: nil,
                    integrity: nil,
                    attribution: nil,
                    status: "write-error",
                    note: describe(error)
                ))
                report.notes.append("\(file.path) could not be written: \(describe(error))")
            }
        }

        report.entries = entries
        report.bytesRead = totalRead
        report.bytesWritten = totalWritten
        report.hashesAgree = allHashesAgree
        report.copyStatus = (failed == 0 && !budgetStopped && !listingPartial) ? "ok" : "partial"
        report.manifestSHA256 = sha256Hex(Data(CopyManifest.digestText(entries: entries).utf8))
        report.createdAt = iso8601(dependencies.now())
        report.manifestPath = destination + "/MANIFEST.json"
        report.summaryPath = destination + "/SUMMARY.txt"

        if listingPartial {
            report.notes.append("the listing was partial, so this copy is not a complete file tree")
        }
        report.notes.append(
            "hash equality proves the copy matches the IMAGE, not that the image matches the platter: "
                + "unreadable regions are zero-filled"
        )
        if report.attribution.kind == "none" {
            report.notes.append(
                "no per-file integrity claim: \(report.attribution.reason ?? "attribution is unavailable")"
            )
        } else {
            if !report.attribution.metadataPaths.isEmpty {
                report.notes.append(
                    "metadata damage named by ntfscluster: "
                        + report.attribution.metadataPaths.joined(separator: ", ")
                        + "; only the affected directories' immediate children are metadata-damaged"
                )
            }
            if !report.attribution.unattributedRanges.isEmpty {
                report.notes.append(
                    "\(report.attribution.unattributedRanges.count) unreadable cluster range(s) belong "
                        + "to no inode (a gap or unallocated clusters); reported at volume level"
                )
            }
        }

        let copied = entries.filter { $0.status == "ok" }.count
        let manifest = CopyManifest(
            createdAt: report.createdAt,
            image: .init(
                path: image,
                sizeBytes: imageSize,
                sha256: report.imageSHA256,
                sha256Note: options.hashImage
                    ? (report.imageSHA256 == nil
                        ? "hashing was requested but did not finish"
                        : "computed because --hash-image was passed")
                    : "not computed: pass --hash-image (hashing a multi-GB image is expensive)"
            ),
            source: .init(
                mapfile: damage.mapfile,
                unreadableExtents: damage.unreadableExtents,
                unreadableBytes: damage.unreadableBytes,
                limitBytes: damage.limitBytes,
                remainingBytes: damage.remainingBytes
            ),
            damage: .init(
                status: damage.status,
                unreadableExtents: damage.unreadableExtents,
                unreadableBytes: damage.unreadableBytes,
                limitBytes: damage.limitBytes,
                note: damage.note
            ),
            attribution: report.attribution,
            copy: .init(
                status: report.copyStatus,
                filesCopied: copied,
                filesFailed: failed,
                bytesRead: totalRead,
                bytesWritten: totalWritten,
                hashesAgree: report.hashesAgree,
                manifestSHA256: report.manifestSHA256
            ),
            entries: entries,
            notes: report.notes
        )

        do {
            try fs.writeFile(try manifest.jsonData(), to: report.manifestPath ?? "")
        } catch {
            return fail(
                .toolError,
                30,
                "the copy finished but MANIFEST.json could not be written: \(describe(error))"
            )
        }

        // Exit-code precedence inside copy: a tool error is 30 (handled above);
        // a partial copy or a mapfile damage/unknown note is 1; a clean copy is 0.
        var code: Int32 = 0
        var status = CopyStatus.ok
        if report.copyStatus != "ok" {
            code = 1
            status = .partial
            report.message = report.notes.first ?? "the copy is partial"
        } else if damage.status == "ok",
                  (damage.unreadableExtents ?? 0) > 0 || (damage.remainingBytes ?? 0) > 0 {
            code = 1
            status = .damage
            report.message = "the mapfile reports damage or unrescued bytes"
        } else if report.attribution.kind == "none",
                  damage.status == "ok",
                  (damage.unreadableExtents ?? 0) > 0 {
            code = 1
            status = .damage
            report.message = "damage is present but per-file attribution is unavailable"
        }
        report.status = status
        report.exitCode = code

        // The human summary is written next to the manifest for a reader who
        // does not parse JSON.
        let summary = renderTTY(report)
        do {
            try fs.writeFile(Data(summary.utf8), to: report.summaryPath ?? "")
        } catch {
            return fail(
                .toolError,
                30,
                "the copy finished but SUMMARY.txt could not be written: \(describe(error))"
            )
        }
        return finish(report, options: options)
    }
}

// MARK: - Attribution

private func attribute(
    tools: any NTFSCopyToolRunning,
    image: String,
    volumeClusters: Int64,
    clusterSize: Int,
    partitionOffset: Int64,
    badExtents: [ByteRange],
    filePaths: [String]
) -> CopyAttribution {
    let result = tools.clusterRuns(image: image, lastCluster: volumeClusters - 1)
    switch result.outcome {
    case .ok:
        if result.stdoutTruncated {
            return .unavailable(
                reason: "ntfscluster output exceeded the process output cap; volume-level reporting only"
            )
        }
        let map = NTFSClusterOutputParser.parse(result.stdout)
        if map.truncated {
            return .unavailable(
                reason: "ntfscluster exceeded the 200,000-run cap; volume-level reporting only"
            )
        }
        if map.runs.isEmpty {
            return .unavailable(
                reason: "ntfscluster named no inode; the MFT is unreadable, so no per-file claim is possible"
            )
        }
        return CopyAttributionEngine.attribute(
            badExtents: badExtents,
            partitionOffset: partitionOffset,
            clusterSize: clusterSize,
            volumeClusters: volumeClusters,
            runs: map.runs,
            filePaths: filePaths
        )
    case .timeout:
        return .unavailable(reason: "ntfscluster did not answer within 120 s; volume-level reporting only")
    case .denied:
        return .unavailable(
            reason: "ntfscluster was denied: " + (firstLine(trimmed(result.stderr)) ?? "no message")
        )
    case .notFound:
        return .unavailable(reason: "ntfscluster disappeared before exec")
    case .policyRejected:
        return .unavailable(reason: "the ntfscluster command was rejected by the command policy")
    case .error:
        return .unavailable(
            reason: "ntfscluster failed: "
                + (firstLine(trimmed(result.stderr))
                    ?? "exit \(result.exitCode.map(String.init) ?? "on a signal")")
        )
    }
}

// MARK: - Tools and paths

private func resolveCopyTools(
    _ dependencies: CopyDependencies
) -> (tools: (any NTFSCopyToolRunning)?, paths: (info: String, ls: String, cat: String, cluster: String)?) {
    if let injected = dependencies.tools {
        if let runner = injected as? NTFSCopyToolRunner {
            let chain = runner.toolchain
            return (injected, (chain.ntfsinfo, chain.ntfsls, chain.ntfscat, chain.ntfscluster))
        }
        return (injected, nil)
    }
    guard dependencies.resolveTools,
          let live = NTFSCopyToolRunner.live(environment: dependencies.environment)
    else {
        return (nil, nil)
    }
    let chain = live.toolchain
    return (live, (chain.ntfsinfo, chain.ntfsls, chain.ntfscat, chain.ntfscluster))
}

private func destinationPath(_ destination: String, _ volumePath: String) -> String {
    let relative = CopyPathRules.relative(volumePath)
    return destination.hasSuffix("/") ? destination + relative : destination + "/" + relative
}

// MARK: - Hashing

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256File(path: String, size: Int64, fs: any CopyFileSystem) throws -> String {
    var hasher = SHA256()
    var offset: Int64 = 0
    let chunk = 1_048_576
    while offset < size {
        let count = Int(min(Int64(chunk), size - offset))
        let data = try fs.read(path, offset: offset, count: count)
        if data.isEmpty { break }
        hasher.update(data: data)
        offset += Int64(data.count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

// MARK: - Rendering

private func finish(_ report: CopyReport, options: CopyOptions) -> CLIResult {
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
            ? "disktriage: \(report.message ?? "the copy stopped")\n"
            : ""
    }
    return CLIResult(stdout: stdout, stderr: stderr, exitCode: report.exitCode)
}

private func renderTTY(_ report: CopyReport) -> String {
    var lines: [String] = []
    lines.append(pad("IMAGE", 11) + report.image)
    lines.append(pad("DEST", 11) + report.destination)

    if let layout = report.layout {
        var text = layout.kind
        if let scheme = layout.scheme { text += " (\(scheme.rawValue))" }
        if let partition = layout.partition { text += " · partition \(partition)" }
        text += " · byte \(layout.offsetBytes), \(layout.lengthBytes) bytes"
        if layout.extracted { text += " · extracted for the tools" }
        lines.append(pad("LAYOUT", 11) + text)
    }

    lines.append(pad("FILESYSTEM", 11) + report.filesystem.rawValue.uppercased())
    if let paths = report.toolPaths {
        lines.append(pad("TOOLS", 11) + "ntfsinfo \(paths.info) · ntfsls \(paths.ls) · "
            + "ntfscat \(paths.cat) · ntfscluster \(paths.cluster)")
    }

    let copied = report.entries.filter { $0.status == "ok" }.count
    let failed = report.entries.count - copied
    lines.append(pad("COPY", 11) + "\(report.copyStatus) · \(copied) file(s) copied"
        + (failed > 0 ? " · \(failed) not copied" : "")
        + " · \(report.bytesRead) bytes read · \(report.bytesWritten) bytes written")

    if report.copyStatus == "ok" {
        lines.append(pad("HASH", 11)
            + "written == read (proves the copy matches the IMAGE, not the platter)")
    } else if report.entries.contains(where: { $0.status == "hash-mismatch" }) {
        lines.append(pad("HASH", 11) + "MISMATCH: the bytes read back differ from the bytes written")
    } else {
        lines.append(pad("HASH", 11) + "not all files were copied, so the copy is not complete")
    }
    lines.append(pad("MANIFEST", 11) + (report.manifestPath ?? "-")
        + " · entries digest \(report.manifestSHA256)")

    if let damage = report.damage {
        switch damage.status {
        case "ok":
            let extents = damage.unreadableExtents ?? 0
            let bytes = damage.unreadableBytes ?? 0
            let notRescued = damage.nonRescuedBytes ?? 0
            lines.append(pad("DAMAGE", 11)
                + "mapfile \(damage.mapfile ?? "?") · \(extents) unreadable "
                + "\(extents == 1 ? "extent" : "extents") · \(bytes) bytes"
                + (notRescued > 0 ? " · \(notRescued) bytes not rescued" : ""))
            if let note = damage.note { lines.append(pad("", 11) + note) }
        case "unsupported":
            lines.append(pad("DAMAGE", 11) + "damage unknown (no mapfile)")
            if let note = damage.note { lines.append(pad("", 11) + note) }
        default:
            lines.append(pad("DAMAGE", 11) + "error · \(damage.note ?? "the mapfile could not be read")")
        }
    }

    if report.attribution.kind == "ntfscluster" {
        lines.append(pad("ATTR", 11) + "ntfscluster · \(report.attribution.filesClaimed) file(s) checked · "
            + "\(report.attribution.filesOverlapping) overlap a bad extent · "
            + "\(report.attribution.filesMetadataDamaged) metadata-damaged · "
            + "\(report.attribution.unattributedRanges.count) bad range(s) in a gap")
    } else {
        lines.append(pad("ATTR", 11) + "none · "
            + (report.attribution.reason ?? "attribution is unavailable")
            + " · no per-file integrity claim")
    }

    let damaged = report.entries.filter {
        ($0.integrity != nil && $0.integrity != .intact)
            || $0.status == "hash-mismatch"
            || $0.status == "read-error"
            || $0.status == "write-error"
            || $0.status == "skipped"
    }
    for entry in damaged.prefix(40) {
        var text = entry.path + " · " + (entry.sizeBytes.map { "\($0) bytes" } ?? "size unknown")
        if let integrity = entry.integrity { text += " · \(integrity.rawValue)" }
        if let attribution = entry.attribution { text += " · \(attribution)" }
        if let note = entry.note { text += " · \(note)" }
        lines.append(pad("FILE", 11) + text)
    }
    if damaged.count > 40 {
        lines.append(pad("FILE", 11) + "… and \(damaged.count - 40) more in MANIFEST.json")
    }

    for note in report.notes {
        lines.append(pad("NOTE", 11) + note)
    }

    let result: String
    switch report.status {
    case .ok:
        if report.damage?.status == "unsupported" {
            result = "copied \(copied) file(s); hashes agree; damage UNKNOWN (no mapfile supplied)"
        } else {
            result = "copied \(copied) file(s); hashes agree; no damage reported"
        }
    case .damage:
        result = "copied \(copied) file(s); hashes agree; damage reported"
    case .partial:
        result = "partial copy: \(failed) file(s) not copied or a hash did not agree"
    case .unsupported:
        result = "tool error (exit 30): \(report.message ?? "unsupported filesystem")"
    case .toolError:
        result = "tool error (exit 30): \(report.message ?? "the copy stopped")"
    }
    lines.append("")
    lines.append(pad("RESULT", 11) + result)
    return lines.joined(separator: "\n") + "\n"
}

private func renderJSON(_ report: CopyReport) -> String {
    var object: [String: Any] = [
        "command": "copy",
        "status": report.status.rawValue,
        "exit_code": Int(report.exitCode),
        "image": report.image,
        "destination": report.destination,
        "filesystem": report.filesystem.rawValue,
        "notes": report.notes,
    ]
    if let message = report.message { object["message"] = message }
    if let manifest = report.manifestPath { object["manifest"] = manifest }
    if let summary = report.summaryPath { object["summary"] = summary }
    object["image_sha256"] = report.imageSHA256 ?? NSNull()

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

    if let paths = report.toolPaths {
        object["tools"] = [
            "ntfsinfo": paths.info,
            "ntfsls": paths.ls,
            "ntfscat": paths.cat,
            "ntfscluster": paths.cluster,
        ]
    } else {
        object["tools"] = NSNull()
    }

    let copied = report.entries.filter { $0.status == "ok" }.count
    object["copy"] = [
        "status": report.copyStatus,
        "files": report.entries.count,
        "files_copied": copied,
        "files_failed": report.entries.count - copied,
        "bytes_read": report.bytesRead,
        "bytes_written": report.bytesWritten,
        "hashes_agree": report.hashesAgree,
        "manifest_sha256": report.manifestSHA256,
    ]

    if let damage = report.damage {
        var value: [String: Any] = [
            "status": damage.status,
            "scope": "volume",
        ]
        value["mapfile"] = damage.mapfile ?? NSNull()
        value["unreadable_extents"] = damage.unreadableExtents.map { $0 } ?? NSNull()
        value["unreadable_bytes"] = damage.unreadableBytes.map { $0 } ?? NSNull()
        value["remaining_bytes"] = damage.remainingBytes.map { $0 } ?? NSNull()
        value["limit_bytes"] = damage.limitBytes.map { $0 } ?? NSNull()
        if let note = damage.note { value["note"] = note }
        object["damage"] = value
    }

    var attribution: [String: Any] = [
        "kind": report.attribution.kind,
        "files_claimed": report.attribution.filesClaimed,
        "files_overlapping": report.attribution.filesOverlapping,
        "files_metadata_damaged": report.attribution.filesMetadataDamaged,
        "metadata_paths": report.attribution.metadataPaths,
        "unattributed_ranges": report.attribution.unattributedRanges.map {
            [
                "first_cluster": $0.first,
                "last_cluster": $0.last,
                "clusters": $0.count,
            ] as [String: Any]
        },
    ]
    attribution["reason"] = report.attribution.reason ?? NSNull()
    object["attribution"] = attribution
    object["files"] = report.entries.map { $0.jsonObject() }

    guard let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let text = String(data: data, encoding: .utf8) else {
        return "{}\n"
    }
    return text + "\n"
}

private func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
}

private let copyUsage = "usage: disktriage copy <image> --to <dir> [options]\n"
    + "\n"
    + "Copies the NTFS file tree out of an image read-only with the ntfs-3g\n"
    + "userspace tools, hashing every byte read and written. Nothing is\n"
    + "mounted and the image is never written. A partial copy or a damaged\n"
    + "image exits 1; a precondition/tool error exits 30.\n"
    + "\n"
    + "  --to <dir>          destination directory (created if missing;\n"
    + "                      existing files are never overwritten)\n"
    + "  --mapfile <path>    damage notes and per-file attribution from this\n"
    + "                      ddrescue mapfile (default: <image>.mapfile)\n"
    + "  --hash-image        also hash the whole image (off by default: a\n"
    + "                      multi-GB image is expensive)\n"
    + "  --json              print the report as JSON\n"
    + "\n"
    + "A device node (/dev/*) is refused with a usage error (2). NTFS only in\n"
    + "v1; other filesystems are named and refused with exit 30.\n"
