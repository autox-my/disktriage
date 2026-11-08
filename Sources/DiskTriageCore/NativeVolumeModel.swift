import Foundation

/// The filesystems `inspect` and `copy` can attach read-only with the native
/// macOS driver. NTFS is deliberately absent: macOS 27.2 has no native NTFS
/// mount, so NTFS stays on the ntfs-3g userspace-tools path (docs/adr/0025).
public enum NativeFilesystem: String, Equatable, Sendable, CaseIterable {
    case apfs
    case hfsPlus = "hfs+"
    case exfat
    case fat

    /// The cheap-magic detector's answer, mapped to the native set. NTFS and
    /// unknown return `nil`: they are not attached this way.
    public init?(kind: FileSystemKind) {
        switch kind {
        case .apfs:
            self = .apfs
        case .hfsPlus:
            self = .hfsPlus
        case .exfat:
            self = .exfat
        case .fat:
            self = .fat
        case .ntfs, .unknown:
            return nil
        }
    }

    /// `diskutil info -plist` reports `FilesystemType` as `apfs`, `hfs`,
    /// `exfat` or `msdos`; the last is a FAT volume, not an MS-DOS image.
    public init?(diskutilType: String) {
        switch diskutilType.lowercased() {
        case "apfs":
            self = .apfs
        case "hfs", "hfs+":
            self = .hfsPlus
        case "exfat":
            self = .exfat
        case "msdos", "fat", "fat32":
            self = .fat
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .apfs: return "APFS"
        case .hfsPlus: return "HFS+"
        case .exfat: return "exFAT"
        case .fat: return "FAT"
        }
    }
}

/// One mountable volume the attach produced. `index` is the 1-based position
/// `inspect` prints and `copy --volume` accepts. For a bare-volume image the
/// device is the whole disk (`/dev/diskN`); for an APFS container it is a
/// synthesized volume (`/dev/diskN sM`).
public struct NativeVolume: Equatable, Sendable {
    public let index: Int
    public let device: String
    public let name: String?
    public let filesystem: NativeFilesystem
    /// A volume that is encrypted at rest. `locked` means it cannot be mounted
    /// without a passphrase; the tool never asks for one.
    public let encrypted: Bool
    public let locked: Bool

    public init(
        index: Int,
        device: String,
        name: String?,
        filesystem: NativeFilesystem,
        encrypted: Bool = false,
        locked: Bool = false
    ) {
        self.index = index
        self.device = device
        self.name = name
        self.filesystem = filesystem
        self.encrypted = encrypted
        self.locked = locked
    }

    /// The name `--volume` accepts, or `volume <index>` when the volume has no
    /// name (a FAT/exFAT volume can be unnamed).
    public var selectorName: String {
        if let name, !name.isEmpty { return name }
        return "volume \(index)"
    }
}

/// Why `copy --volume` could not pick exactly one volume.
public enum NativeVolumeSelectionError: Error, Equatable, Sendable {
    /// The attach produced no volume of the requested filesystem.
    case noVolumes
    /// More than one volume and no `--volume`: the copy must not guess.
    case multipleVolumes
    /// The selector matched no volume, or more than one name.
    case unknownSelector(String)
}

public enum NativeVolumeSelection {
    /// Picks the one volume `copy` may read. A single volume needs no
    /// selector; more than one requires `--volume <name|index>`; a name that
    /// matches two volumes is ambiguous and refused rather than guessed.
    public static func select(
        _ volumes: [NativeVolume],
        selector: String?
    ) -> Result<NativeVolume, NativeVolumeSelectionError> {
        guard !volumes.isEmpty else { return .failure(.noVolumes) }
        guard let selector else {
            return volumes.count == 1 ? .success(volumes[0]) : .failure(.multipleVolumes)
        }

        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = Int(trimmed), index > 0 {
            guard let volume = volumes.first(where: { $0.index == index }) else {
                return .failure(.unknownSelector(selector))
            }
            return .success(volume)
        }

        let exact = volumes.filter { $0.name == selector }
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 { return .failure(.unknownSelector(selector)) }

        // APFS volume names are case-insensitive on macOS, so a
        // case-insensitive match is accepted only when it is unique.
        let folded = volumes.filter {
            $0.name?.caseInsensitiveCompare(selector) == .orderedSame
        }
        if folded.count == 1 { return .success(folded[0]) }
        return .failure(.unknownSelector(selector))
    }

    /// One human line per volume, used in the refusal message so the user can
    /// see exactly what `--volume` accepts.
    public static func describe(_ volumes: [NativeVolume]) -> String {
        volumes.map { volume in
            var text = "\(volume.index): \(volume.selectorName) (\(volume.device), "
                + volume.filesystem.displayName
            if volume.locked {
                text += ", locked"
            } else if volume.encrypted {
                text += ", encrypted"
            }
            text += ")"
            return text
        }.joined(separator: "; ")
    }
}
