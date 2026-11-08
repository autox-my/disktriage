#!/usr/bin/env bash
# generate.sh — build the native filesystem live-test fixtures.
#
#   tools/native-fixture/generate.sh [output-dir]
#
# The images are synthetic, deterministic in their file set, and gitignored
# (tens of MiB each). scripts/bootstrap.sh runs this once. The product never
# runs a writable attach; this generator is the only place that does, and only
# on images it just created under the output directory.
#
# Images:
#   exfat-disk.img       64 MiB GPT whole-disk, exFAT
#   exfat-part.img       the exFAT partition extracted (a bare volume)
#   fat-disk.img         64 MiB GPT whole-disk, FAT32 (MS-DOS)
#   fat-part.img         the FAT partition extracted
#   hfs-disk.dmg         64 MiB GPT whole-disk, HFS+
#   hfs-part.img         the HFS+ partition extracted
#   apfs-disk.img        2 GiB GPT whole-disk, APFS with two volumes
#   encrypted-apfs.img   64 MiB APFS volume, FileVault-encrypted and locked
#   damaged-exfat-part.img + .mapfile
#                        a copy of exfat-part.img with a hand-written mapfile
#                        that reports one unreadable 64 KiB extent (the image
#                        itself is intact: the mapfile is the damage evidence)
#
# No sudo. No physical disk is named. The only disks touched are the ones the
# attach output names for an image under this output directory, and every one
# is ejected on every exit path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
OUT="${1:-${DISKTRIAGE_NATIVE_FIXTURE_DIR:-$ROOT/.build/fixtures/native}}"
GENERATOR="$ROOT/tools/native-fixture/generate.sh"
STAMP="$OUT/.stamp"
PASSPHRASE="disktriage-fixture"

EXPECTED=(
    exfat-disk.img
    exfat-part.img
    fat-disk.img
    fat-part.img
    hfs-disk.dmg
    hfs-part.img
    apfs-disk.img
    encrypted-apfs.img
    damaged-exfat-part.img
    damaged-exfat-part.mapfile
)

note() { printf '%s\n' "$*"; }
die() { note "FAIL          $*"; exit 1; }

for tool in diskutil hdiutil python3 dd; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

mkdir -p "$OUT" || die "cannot create $OUT"
OUT="$(cd "$OUT" && pwd)" || die "cannot resolve $OUT"

complete() {
    local name
    for name in "${EXPECTED[@]}"; do
        [ -f "$OUT/$name" ] || return 1
    done
    return 0
}

if [ -f "$STAMP" ] && complete && [ "$(cat "$STAMP")" = "$(shasum -a 256 "$GENERATOR" | awk '{print $1}')" ]; then
    note "PASS          native fixtures already current in $OUT"
    exit 0
fi

# Only our own generated names are removed; nothing else under $OUT is touched.
rm -f "$OUT/exfat-disk.img" "$OUT/exfat-part.img" \
      "$OUT/fat-disk.img" "$OUT/fat-part.img" \
      "$OUT/hfs-disk.dmg" "$OUT/hfs-part.img" \
      "$OUT/apfs-disk.img" "$OUT/encrypted-apfs.img" \
      "$OUT/damaged-exfat-part.img" "$OUT/damaged-exfat-part.mapfile" \
      "$STAMP"

WHOLE=""
MOUNTS=()

cleanup() {
    local mp
    for mp in "${MOUNTS[@]:-}"; do
        [ -n "$mp" ] || continue
        diskutil unmount "$mp" >/dev/null 2>&1 || true
        rm -rf "$mp"
    done
    if [ -n "$WHOLE" ]; then
        diskutil eject "$WHOLE" >/dev/null 2>&1 || true
    fi
    WHOLE=""
    MOUNTS=()
}
trap cleanup EXIT INT TERM

attach_rw() {
    local image="$1" mount_point="$2"
    local output
    mkdir -p "$mount_point" || return 1
    output="$(diskutil image attach --mountPoint "$mount_point" "$image" 2>&1)" || {
        note "$output"
        return 1
    }
    WHOLE="$(printf '%s\n' "$output" | awk 'NR==1{print $1}')"
    case "$WHOLE" in
        /dev/disk*) ;;
        *) note "attach named no whole disk: $output"; return 1 ;;
    esac
    MOUNTS+=("$mount_point")
    if ! mount | grep -F " $mount_point " >/dev/null 2>&1; then
        note "the image attached but $mount_point is not mounted"
        return 1
    fi
}

detach() {
    local mp
    for mp in "${MOUNTS[@]:-}"; do
        [ -n "$mp" ] || continue
        diskutil unmount "$mp" >/dev/null 2>&1 || true
    done
    for mp in "${MOUNTS[@]:-}"; do
        [ -n "$mp" ] || continue
        rm -rf "$mp"
    done
    MOUNTS=()
    if [ -n "$WHOLE" ]; then
        diskutil eject "$WHOLE" >/dev/null 2>&1 || true
    fi
    WHOLE=""
}

populate() {
    local mount_point="$1" marker="$2"
    mkdir -p "$mount_point/docs" "$mount_point/media" "$mount_point/empty" \
             "$mount_point/nested/deep" || return 1
    printf 'disktriage native fixture %s\n' "$marker" >"$mount_point/docs/readme.txt"
    printf 'unicode name fixture %s\n' "$marker" >"$mount_point/docs/résumé-日本語.txt"
    printf 'nested %s\n' "$marker" >"$mount_point/nested/deep/note.txt"
    python3 - "$mount_point/media/payload.bin" "$marker" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
# 1 MiB of a fixed pattern, with the marker in the first bytes. Deterministic
# in content; the filesystem's own metadata (serial, timestamps) is not.
prefix = ("disktriage-payload:" + marker + "\n").encode()
data = (prefix + bytes(range(256)) * 4096)[:1024 * 1024]
with open(path, "wb") as handle:
    handle.write(data)
PY
    [ -d "$mount_point/empty" ]
}

first_partition() {
    # Prints "<start-lba> <sector-count>" for the first GPT entry.
    python3 - "$1" <<'PY'
import struct
import sys
path = sys.argv[1]
with open(path, "rb") as handle:
    handle.seek(512)
    header = handle.read(512)
    if header[:8] != b"EFI PART":
        raise SystemExit("no GPT header")
    entries_lba = struct.unpack_from("<Q", header, 72)[0]
    count = struct.unpack_from("<I", header, 80)[0]
    size = struct.unpack_from("<I", header, 84)[0]
    handle.seek(entries_lba * 512)
    entries = handle.read(count * size)
for index in range(count):
    entry = entries[index * size:(index + 1) * size]
    if not any(entry[:16]):
        continue
    first, last = struct.unpack_from("<QQ", entry, 32)
    print(first, last - first + 1)
    raise SystemExit(0)
raise SystemExit("no partition")
PY
}

extract_partition() {
    local image="$1" destination="$2"
    local geometry start count
    geometry="$(first_partition "$image")" || die "cannot parse the partition table of $image"
    start="${geometry%% *}"
    count="${geometry##* }"
    dd if="$image" of="$destination" bs=512 skip="$start" count="$count" status=none \
        || die "cannot extract the partition from $image"
}

# 1. exFAT, FAT and APFS whole-disk images.
note "== exFAT, FAT, APFS images =="
diskutil image create blank --format RAW --size 64m --volumeName DTEXFAT --fs ExFAT \
    "$OUT/exfat-disk.img" >/dev/null 2>&1 || die "cannot create the exFAT image"
diskutil image create blank --format RAW --size 64m --volumeName DTFAT --fs MS-DOS \
    "$OUT/fat-disk.img" >/dev/null 2>&1 || die "cannot create the FAT image"
diskutil image create blank --format RAW --size 2g --volumeName DTAPFS1 --fs APFS \
    "$OUT/apfs-disk.img" >/dev/null 2>&1 || die "cannot create the APFS image"

# 2. HFS+ (diskutil image create has no HFS+ filesystem option).
note "== HFS+ image =="
hdiutil create -size 64m -fs HFS+ -volname DTHFS -quiet "$OUT/hfs-disk.dmg" \
    >/dev/null 2>&1 || die "cannot create the HFS+ image"

# 3. Populate each single-volume image through a read-write attach. This is the
#    fixture generator's only writable attach; the product never does this.
populate_image() {
    local image="$1" marker="$2" mount_point="$OUT/.mnt-$2"
    note "== populate $marker =="
    attach_rw "$image" "$mount_point" || die "cannot attach $image read-write"
    populate "$mount_point" "$marker" || die "cannot populate $image"
    detach
    rm -rf "$mount_point"
}

populate_image "$OUT/exfat-disk.img" "exfat"
populate_image "$OUT/fat-disk.img" "fat"
populate_image "$OUT/hfs-disk.dmg" "hfs"

# 4. APFS with two volumes.
note "== populate apfs (two volumes) =="
APFS_MNT1="$OUT/.mnt-apfs1"
mkdir -p "$APFS_MNT1" || die "cannot create the APFS mountpoint"
apfs_output="$(diskutil image attach --mountPoint "$APFS_MNT1" "$OUT/apfs-disk.img" 2>&1)" \
    || die "cannot attach the APFS image read-write"
WHOLE="$(printf '%s\n' "$apfs_output" | awk 'NR==1{print $1}')"
CONTAINER="$(printf '%s\n' "$apfs_output" | awk '$2=="Apple_APFS_Container"{print $1}')"
[ -n "$CONTAINER" ] || die "the APFS image has no container"
MOUNTS+=("$APFS_MNT1")
populate "$APFS_MNT1" "apfs-one" || die "cannot populate the first APFS volume"

diskutil apfs addVolume "$CONTAINER" APFS DTAPFS2 >/dev/null 2>&1 \
    || die "cannot add the second APFS volume"
# `addVolume` creates the container's next slice; on a freshly created image
# that is always s2. It is never taken from a global `diskutil list` scan, so
# the generator cannot mount a system volume by accident.
SECOND="${CONTAINER}s2"
diskutil mount "$SECOND" >/dev/null 2>&1 \
    || die "cannot mount the second APFS volume"
# `diskutil mount -mountPoint` is ignored for an APFS volume (measured on
# 27.2: it mounts under /Volumes anyway), so the generator asks where the
# volume actually landed rather than assuming.
SECOND_MOUNT="$(diskutil info "$SECOND" | sed -n 's/^ *Mount Point: *//p' | head -1)"
[ -n "$SECOND_MOUNT" ] || die "the second APFS volume has no mount point"
MOUNTS+=("$SECOND_MOUNT")
populate "$SECOND_MOUNT" "apfs-two" || die "cannot populate the second APFS volume"
mkdir -p "$SECOND_MOUNT/second"
printf 'only on the second APFS volume\n' >"$SECOND_MOUNT/second/only-on-two.txt"
detach
rm -rf "$APFS_MNT1"

# 5. A locked, encrypted APFS volume. The passphrase exists only here, so the
#    product cannot unlock it and must refuse without prompting.
note "== encrypted APFS image =="
diskutil image create blank --format RAW --size 64m --volumeName DTENC --fs APFS \
    "$OUT/encrypted-apfs.img" >/dev/null 2>&1 || die "cannot create the encrypted APFS image"
ENC_MNT="$OUT/.mnt-enc"
mkdir -p "$ENC_MNT" || die "cannot create the encrypted mountpoint"
enc_output="$(diskutil image attach --mountPoint "$ENC_MNT" "$OUT/encrypted-apfs.img" 2>&1)" \
    || die "cannot attach the encrypted image read-write"
WHOLE="$(printf '%s\n' "$enc_output" | awk 'NR==1{print $1}')"
ENC_VOL="$(printf '%s\n' "$enc_output" | awk '$2=="Apple_APFS_Volume"{print $1}')"
[ -n "$ENC_VOL" ] || die "the encrypted image has no APFS volume"
MOUNTS+=("$ENC_MNT")
populate "$ENC_MNT" "encrypted" || die "cannot populate the encrypted volume"
diskutil apfs encryptVolume "$ENC_VOL" -user disk -passphrase "$PASSPHRASE" >/dev/null 2>&1 \
    || die "cannot encrypt the APFS volume"
# The volume is locked as soon as the crypto user exists; the background
# encryption itself may continue, which is fine for the refusal test.
detach
rm -rf "$ENC_MNT"

# 6. Bare partitions and the mapfile damage fixture.
note "== bare partitions and damage fixture =="
extract_partition "$OUT/exfat-disk.img" "$OUT/exfat-part.img"
extract_partition "$OUT/fat-disk.img" "$OUT/fat-part.img"
extract_partition "$OUT/hfs-disk.dmg" "$OUT/hfs-part.img"
cp "$OUT/exfat-part.img" "$OUT/damaged-exfat-part.img" \
    || die "cannot copy the damaged-image fixture"
SIZE="$(stat -f%z "$OUT/damaged-exfat-part.img")" || die "cannot stat the damaged fixture"
python3 - "$OUT/damaged-exfat-part.mapfile" "$SIZE" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
start = 0x00100000
hole = 0x00010000
if start + hole >= size:
    raise SystemExit("the image is too small for the synthetic hole")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("# Mapfile. Created by hand for the disktriage native fixture\n")
    handle.write("# The image is intact; this mapfile is the damage evidence.\n")
    handle.write("# Finished\n")
    handle.write("# current_pos  current_status  current_pass\n")
    handle.write("0x00000000     +               1\n")
    handle.write("#      pos        size  status\n")
    handle.write("0x%08X  0x%08X  +\n" % (0, start))
    handle.write("0x%08X  0x%08X  -\n" % (start, hole))
    handle.write("0x%08X  0x%08X  +\n" % (start + hole, size - (start + hole)))
PY

printf '%s' "$(shasum -a 256 "$GENERATOR" | awk '{print $1}')" >"$STAMP" \
    || die "cannot write the fixture stamp"
note "PASS          native fixtures in $OUT"
