# `minah-scope-mapfile.txt` — the first real `--scope-report` run

Redacted from `captures/minah-scope/mapfile-final.txt` on the failing MiNaH
drive (WD3200BJKT behind a USB 2 bridge). Every local path in the `# Command
line:` header is replaced with a placeholder; the extent rows are copied
verbatim.

The stage-0 `$Bitmap` data read is the domain extent
`0x2542E8A000 .. 0x25437DB000` (size `0x951000` = 9,768,960 bytes). Inside it
the main mapfile has three non-`+` rows:

```
0x2543301000  0x00000600  -     1536 bytes, confirmed bad
0x2543301600  0x00000800  /     2048 bytes, not scraped
0x2543301E00  0x00000200  -      512 bytes, confirmed bad
```

The three rows are adjacent (`0x600 + 0x800 + 0x200 = 0x1000`), so the
untrustworthy region is one 4096-byte stretch of bitmap bytes starting at

```
0x2543301000 - 0x2542E8A000 = 0x00477000 = 4,681,728
```

A bitmap byte covers eight clusters (one bit per cluster), so 4096 bytes cover
`4,681,728 × 8 = 37,453,824` through `37,453,824 + 32,768 - 1 = 37,486,591`:
**32,768 unknown clusters**, which is 128 MiB at the volume's 4096-byte
clusters. The recorded `scope1.json` said 78,142,207 total clusters, 60,108,549
used and 18,033,658 free; 32,768 of that free count were unreadable allocation,
not free.

The values are hand arithmetic from the mapfile rows, not produced by the code
under test.
