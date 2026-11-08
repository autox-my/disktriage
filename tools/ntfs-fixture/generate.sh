#!/usr/bin/env bash
# Deterministic NTFS fixture generator for the live tests. NOT product code.
#
#   tools/ntfs-fixture/generate.sh <ntfs-prefix> <output-dir> <nfixture>
#
# The output is synthetic: mkntfs creates an empty 64 MiB NTFS volume and the
# files are written by ntfscp from a fixed, seeded file set. No device data,
# no serial and nothing from a real disk goes into these images.
#
# The layout is deterministic: the file set, its order, the filler loop and
# the deletion pattern are fixed. mkntfs writes a fresh volume serial and
# timestamps, so the bytes differ run to run; the tests assert layout facts
# (used clusters, free clusters, used runs, MFT/bitmap locations, file sizes),
# never those bytes.
#
# Outputs (under <output-dir>):
#   part.img                     the 64 MiB NTFS volume (hidden sectors 2048)
#   disk.img                     80 MiB: MBR + part.img at LBA 2048 + zero tail
#   damaged-clip-part.img        part.img with a 64 KiB hole at cluster 8735
#   damaged-clip-part.mapfile    the ddrescue mapfile for that hole
#
# Idempotent: a stamp naming the generator version and the prefix skips the
# whole run when every output is already present.
set -euo pipefail

PREFIX="${1:?usage: generate.sh <ntfs-prefix> <output-dir> <nfixture>}"
OUT="${2:?usage: generate.sh <ntfs-prefix> <output-dir> <nfixture>}"
NFIX="${3:?usage: generate.sh <ntfs-prefix> <output-dir> <nfixture>}"

GENERATOR_VERSION="1"
VOLUME_BYTES=67108864          # 64 MiB
DISK_BYTES=83886080            # 80 MiB
PARTITION_OFFSET=1048576       # LBA 2048 * 512
PARTITION_SECTORS=131072
DAMAGE_OFFSET=0x221F000        # cluster 8735 * 4096
DAMAGE_BYTES=0x10000           # 64 KiB, clusters 8735-8750

MKNTFS="$PREFIX/sbin/mkntfs"
NTFSCP="$PREFIX/sbin/ntfscp"
NTFSINFO="$PREFIX/bin/ntfsinfo"
NTFSCLUSTER="$PREFIX/bin/ntfscluster"

for tool in "$MKNTFS" "$NTFSCP" "$NTFSINFO" "$NTFSCLUSTER" "$NFIX"; do
    [ -x "$tool" ] || { echo "missing executable: $tool" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

mkdir -p "$OUT"
STAMP="$OUT/.generated"
STAMP_VALUE="$GENERATOR_VERSION|$PREFIX"

all_outputs_present() {
    [ -f "$OUT/part.img" ] && [ -f "$OUT/disk.img" ] \
        && [ -f "$OUT/damaged-clip-part.img" ] \
        && [ -f "$OUT/damaged-clip-part.mapfile" ]
}

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$STAMP_VALUE" ] && all_outputs_present; then
    echo "fixtures up to date: $OUT"
    exit 0
fi

PART="$OUT/part.img"
rm -f "$PART" "$OUT/disk.img" "$OUT/damaged-clip-part.img" \
    "$OUT/damaged-clip-part.mapfile" "$OUT/mkntfs.log"

# 1. A fresh 64 MiB NTFS volume. -T zeroes the timestamps and -L matches the
#    recorded fixture's label; neither changes the allocation layout. -p 2048
#    records the partition start in the boot sector, as the recorded part.img
#    does.
truncate -s "$VOLUME_BYTES" "$PART"
"$MKNTFS" -F -Q -q -T -L NTFS64 -p 2048 "$PART" "$PARTITION_SECTORS" \
    >"$OUT/mkntfs.log" 2>&1

WORK="$OUT/.work"
rm -rf "$WORK"
mkdir -p "$WORK"

# 2. The fixed, seeded file set. Sizes are what the tests assert; the content
#    is deterministic and is never committed.
python3 - "$WORK" <<'PY'
import os, random, sys
work = sys.argv[1]
rng = random.Random(20261106)
def write(name, size):
    with open(os.path.join(work, name), "wb") as handle:
        handle.write(rng.randbytes(size))
write("big.bin", 8 * 1024 * 1024)
write("fill.bin", 2 * 1024 * 1024)
for size in [0, 1, 100, 511, 512, 4095, 4096, 4097, 65536, 131072, 1048576]:
    write("size-%d.bin" % size, size)
write("readme.txt", 2048)
write("tiny-resident.txt", 10)
write("notes.md", 16384)
write("clip.dat", 262144)
write("leaf.dat", 65536)
write("latin.bin", 300)
PY

"$NFIX" mkdir "$PART" /docs/2026
"$NFIX" mkdir "$PART" /media
"$NFIX" mkdir "$PART" /deep/a/b/c
"$NFIX" mkdir "$PART" /empty-dir

put() { "$NTFSCP" -f "$PART" "$WORK/$1" "$2" >/dev/null; }

put readme.txt "/docs/readme.txt"
put tiny-resident.txt "/docs/tiny-resident.txt"
put notes.md "/docs/2026/notes.md"
put latin.bin "/docs/2026/résumé-日本語.txt"
put leaf.dat "/deep/a/b/c/leaf.dat"
put clip.dat "/media/clip.dat"
for size in 0 1 100 511 512 4095 4096 4097 65536 131072 1048576; do
    put "size-$size.bin" "/media/size-$size.bin"
done

# 3. Fill the volume until 8 MiB cannot fit whole, then punch every third
#    filler so big.bin has to fragment. This is the recorded layout recipe.
free_clusters() {
    "$NTFSINFO" -m "$PART" | sed -n 's/.*Free Clusters: \([0-9]*\).*/\1/p'
}
filler=0
while [ "$(free_clusters)" -gt 1024 ]; do
    put fill.bin "$(printf '/media/frag-%02d.bin' "$filler")"
    filler=$((filler + 1))
done
for k in $(seq 0 $((filler - 1))); do
    if [ $((k % 3)) -eq 0 ]; then
        "$NFIX" rm "$PART" "$(printf '/media/frag-%02d.bin' "$k")"
    fi
done
put big.bin "/media/big.bin"

# 4. disk.img: a 512-byte MBR (one type-0x07 partition at LBA 2048, 131072
#    sectors, 55 AA), a 1 MiB zero gap, the volume, and a zero tail to 80 MiB.
python3 - "$OUT/disk.img" "$PART" "$PARTITION_OFFSET" "$DISK_BYTES" "$PARTITION_SECTORS" <<'PY'
import struct, sys
disk_path, part_path, offset, disk_bytes, sectors = sys.argv[1:]
offset, disk_bytes, sectors = int(offset), int(disk_bytes), int(sectors)
part = open(part_path, "rb").read()
mbr = bytearray(512)
entry = bytearray(16)
entry[0] = 0x00          # not bootable
entry[4] = 0x07          # NTFS / HPFS
struct.pack_into("<I", entry, 8, offset // 512)
struct.pack_into("<I", entry, 12, sectors)
mbr[446:462] = entry
mbr[510] = 0x55
mbr[511] = 0xAA
with open(disk_path, "wb") as out:
    out.write(mbr)
    out.write(b"\0" * (offset - len(mbr)))
    out.write(part)
    out.write(b"\0" * (disk_bytes - offset - len(part)))
PY

# 5. The damaged copy: one 64 KiB hole inside /media/clip.dat's run 8725-8788,
#    and the mapfile that reports it as a bad sector.
cp "$PART" "$OUT/damaged-clip-part.img"
python3 - "$OUT/damaged-clip-part.img" "$DAMAGE_OFFSET" "$DAMAGE_BYTES" <<'PY'
import sys
path, offset, length = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
with open(path, "r+b") as handle:
    handle.seek(offset)
    handle.write(b"\0" * length)
PY

python3 - "$OUT/damaged-clip-part.mapfile" "$VOLUME_BYTES" "$DAMAGE_OFFSET" "$DAMAGE_BYTES" <<'PY'
import sys
path, size, offset, length = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 0), int(sys.argv[4], 0)
lines = [
    "# Mapfile. Created by hand for the disktriage NTFS fixture",
    "# Command line: simulated mapfile, no device was read",
    "# Start time:   2026-11-06 23:10:00",
    "# Current time: 2026-11-06 23:20:00",
    "# Finished",
    "# current_pos  current_status  current_pass",
    "0x%08X     +               1" % 0,
    "#      pos        size  status",
]
if offset > 0:
    lines.append("0x%08X  0x%08X  +" % (0, offset))
lines.append("0x%08X  0x%08X  -" % (offset, length))
end = offset + length
if end < size:
    lines.append("0x%08X  0x%08X  +" % (end, size - end))
open(path, "w").write("\n".join(lines) + "\n")
PY

rm -rf "$WORK"
printf '%s\n' "$STAMP_VALUE" >"$STAMP"

# 6. Print the facts the tests assert, so a generation is its own evidence.
echo "generated fixtures in $OUT"
"$NTFSINFO" -m "$PART" | sed -n 's/.*Free Clusters: \([0-9]*\).*/free clusters: \1/p'
"$NTFSCLUSTER" -c 0-16382 -v "$PART" 2>/dev/null | python3 -c '
import re, sys
clusters = set()
for line in sys.stdin:
    match = re.match(r"\s+\d+\s+(\d+)-(\d+)\s+\(", line)
    if match:
        clusters.update(range(int(match.group(1)), int(match.group(2)) + 1))
runs = 0
previous = None
for cluster in sorted(clusters):
    if previous is None or cluster != previous + 1:
        runs += 1
    previous = cluster
print("used clusters: %d; coalesced used runs: %d" % (len(clusters), runs))
'
