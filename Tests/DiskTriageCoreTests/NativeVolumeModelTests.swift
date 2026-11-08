import Testing
@testable import DiskTriageCore

/// `copy --volume` selection is pure: it decides from the attach's volume list
/// and never guesses. A single volume needs no selector; several do.
struct NativeVolumeModelTests {
    private func volumes() -> [NativeVolume] {
        [
            NativeVolume(index: 1, device: "/dev/disk9s1", name: "DTAPFS1", filesystem: .apfs),
            NativeVolume(index: 2, device: "/dev/disk9s2", name: "DTAPFS2", filesystem: .apfs),
        ]
    }

    // REQ-0287, REQ-0288
    @Test("REQ0287_REQ0288 a single volume needs no selector and several refuse without one")
    func REQ0287_REQ0288_singleNeedsNoSelectorAndSeveralRequireOne() {
        let one = [NativeVolume(index: 1, device: "/dev/disk8", name: "DT", filesystem: .exfat)]
        #expect(NativeVolumeSelection.select(one, selector: nil) == .success(one[0]))
        #expect(
            NativeVolumeSelection.select(volumes(), selector: nil)
                == .failure(.multipleVolumes)
        )
        #expect(NativeVolumeSelection.select([], selector: nil) == .failure(.noVolumes))
    }

    // REQ-0289
    @Test("REQ0289 --volume selects by 1-based index")
    func REQ0289_selectsByOneBasedIndex() {
        #expect(
            NativeVolumeSelection.select(volumes(), selector: "2")
                == .success(volumes()[1])
        )
        #expect(
            NativeVolumeSelection.select(volumes(), selector: "0")
                == .failure(.unknownSelector("0")),
            "index 0 is not a volume: the CLI prints 1-based indexes"
        )
        #expect(
            NativeVolumeSelection.select(volumes(), selector: "3")
                == .failure(.unknownSelector("3"))
        )
    }

    // REQ-0290
    @Test("REQ0290 --volume selects by name, case-insensitively when unique")
    func REQ0290_selectsByName() {
        #expect(
            NativeVolumeSelection.select(volumes(), selector: "DTAPFS2")
                == .success(volumes()[1])
        )
        #expect(
            NativeVolumeSelection.select(volumes(), selector: "dtapfs1")
                == .success(volumes()[0])
        )
    }

    // REQ-0291
    @Test("REQ0291 --volume refuses an unknown or ambiguous selector")
    func REQ0291_refusesUnknownOrAmbiguousSelector() {
        #expect(
            NativeVolumeSelection.select(volumes(), selector: "not-there")
                == .failure(.unknownSelector("not-there"))
        )
        let ambiguous = [
            NativeVolume(index: 1, device: "/dev/disk9s1", name: "Same", filesystem: .apfs),
            NativeVolume(index: 2, device: "/dev/disk9s2", name: "Same", filesystem: .apfs),
        ]
        #expect(
            NativeVolumeSelection.select(ambiguous, selector: "Same")
                == .failure(.unknownSelector("Same")),
            "two volumes with the same name are never guessed between"
        )
    }

    // REQ-0305
    @Test("REQ0305 the volume description names every index, name, device and lock state")
    func REQ0305_describesEveryVolume() {
        let text = NativeVolumeSelection.describe([
            NativeVolume(index: 1, device: "/dev/disk9s1", name: "DTAPFS1", filesystem: .apfs),
            NativeVolume(
                index: 2,
                device: "/dev/disk9s2",
                name: nil,
                filesystem: .apfs,
                encrypted: true,
                locked: true
            ),
        ])
        #expect(text.contains("1: DTAPFS1 (/dev/disk9s1, APFS"))
        #expect(text.contains("2: volume 2 (/dev/disk9s2, APFS, locked"))
    }

    @Test("the native filesystem mapping is explicit")
    func mapsDiskutilTypes() {
        #expect(NativeFilesystem(kind: .ntfs) == nil, "NTFS is not a native attach")
        #expect(NativeFilesystem(kind: .unknown) == nil)
        #expect(NativeFilesystem(diskutilType: "msdos") == .fat)
        #expect(NativeFilesystem(diskutilType: "hfs") == .hfsPlus)
        #expect(NativeFilesystem(diskutilType: "exfat") == .exfat)
        #expect(NativeFilesystem(diskutilType: "apfs") == .apfs)
        #expect(NativeFilesystem(diskutilType: "ntfs") == nil)
    }
}
