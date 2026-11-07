# `ntfs-disk-*` fixtures — recorded from the P0 NTFS spike

Source: the synthetic, gitignored image `captures/ntfs-spike/img/disk.img`
(80 MiB: MBR + a 64 MiB NTFS partition at byte 1,048,576) and its extracted
volume `captures/ntfs-spike/img/part.img`. The images were made by this
project with `mkntfs`; they carry no device serial. The committed bytes are the
few KiB the pure parser needs.

| Fixture | Source |
|---|---|
| `ntfs-disk-boot-primary.bin` | `part.img[0..<512]`, identical to `disk.img[1048576..<1049088]` |
| `ntfs-disk-boot-backup.bin` | `part.img[67108352..<67108864]`, identical to `disk.img[68156928..<68157440]` |
| `ntfs-disk-mft-record-0.bin` | `part.img[16384..<17408]` (MFT LCN 4, record 0 = `$MFT`) |
| `ntfs-disk-mft-record-6.bin` | `part.img[22528..<23552]` (record 6 = `$Bitmap`) |
| `ntfs-disk-bitmap.bin` | `part.img[8417280..<8419328]` (2048 bytes, `$Bitmap` data at LCN 2055) |
| `ntfs-disk-ntfscluster.txt` | raw `ntfscluster -c 0-16382 -v img/part.img` output |
| `ntfs-disk-used-runs.txt` | the coalesced union of that output, cross-checked against `ntfsinfo` |

Expectations recorded from ntfs-3g 2026.9.28 (the spike prefix):

```
$ ntfsinfo -m img/part.img
        Sector Size: 512
        Cluster Size: 4096
        Index Block Size: 4096
        Volume Size in Clusters: 16383
        MFT Record Size: 1024
        LCN of Data Attribute for FILE_MFT: 4
        LCN of Data Attribute for File_MFTMirr: 8191
        Attribute Allocated Size: 4096
        Attribute Data Size: 2048
        Free Clusters: 4075 (24.9%)

$ ntfscluster -c 0-16382 -v img/part.img
        Inode 0 /$MFT/$DATA      0       4-34 (31)
        Inode 1 /$MFTMirr/$DATA  0       8191-8191 (1)
        Inode 6 /$Bitmap/$DATA   0       2055-2055 (1)
        ... (the full output is the ntfscluster fixture)
```

The boot sector's BPB `total_sectors` is 131071 (one sector short of the
partition's 131072), which is why the backup offset comes from the partition
table. `disk.img[68156928]` is where that formula lands, and it is the byte
fixture above.

MFT record 0's `$DATA` runlist is `11 1f 04 00` → VCN 0, 31 clusters, LCN 4.
Record 6's is `21 01 07 08 00` → VCN 0, 1 cluster, LCN 2055. Both records carry
USA fixups (USN `0x0037` and `0x0002`; the restored sector-tail words are zero).

The bitmap fixture's last byte is `0xFF`; bit 16383 is set in the image but lies
past `Volume Size in Clusters: 16383`, so the parser must ignore it. Counting it
would make 12309 used clusters instead of the tool's 12308.
