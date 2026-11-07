# 0007. CLI decisions (P3c, streaming `copy`)

Status: accepted
Date: 2026-11-07

## Context

`copy` used to buffer each `ntfscat` stdout in memory. It now streams, so peak
memory is one chunk regardless of file size. The contract did not change for
small files: the same manifest, the same hashes, the same exit codes.

## Decision

- **The stream is `ProcessRunner.stream`.** It is a sibling of `runData`, not a
  weaker path: the same `CommandPolicy` check before `exec`, the same hard
  timeout, and the same `TERM`-then-`KILL` to the process group. stdout is read
  non-blocking through one pipe in `CopyLimits.streamChunkBytes` (1 MiB) chunks;
  stderr is drained concurrently and still capped by `outputLimit`. A throwing
  sink stops the child, so a full disk never leaves a tool writing into a pipe.
- **Memory is O(chunk).** The read-side SHA-256 is updated incrementally,
  including the final partial chunk; the chunk is written to the temporary file
  before it leaves the loop. `--max-bytes` and the per-file bound are checked
  before a chunk is written, so a cap never creates a partial final file.
- **A file is installed only after its read-back.** Data goes to
  `.<name>.disktriage-partial.<uuid>` beside its target. `sync` fsyncs it, a
  bounded read-back re-hashes those bytes, and only an agreeing read-back calls
  `commit`. `commit` fsyncs again and installs with `link`+`unlink`, which is an
  atomic no-replace operation: a file that appeared at the destination is a
  failure, never an overwrite. Any failure, timeout or cap calls `abort`, which
  deletes the temporary file; a process that dies leaves a visibly partial name,
  never a plausible final one.
- **Unfinished is `incomplete`, never copied.** A stream that ends by timeout or
  cap, or a write/read-back failure, records `status: "incomplete"` with the
  bytes streamed and a note saying the partial file was discarded. It is not
  `ok`, not counted in `files_copied`, and makes `copy.status` `partial` (exit
  1). A complete-but-corrupt write is `hash-mismatch`; a tool that never
  produced data keeps `read-error`.
- **Caps are not memory bounds.** The per-file sanity bound is 2 TiB and is
  refused before a read when the listing names the size. `--max-bytes <GiB>`
  (positive whole GiB; zero, a fraction or a non-number is usage error 2) is the
  only run-wide byte cap; without it the 1,800 s run budget and the per-tool
  hard timeouts remain. Hitting either prints the cap and the remaining file
  count; the manifest's `copy.max_bytes` is the cap in bytes (null when absent).

## Consequences

- **Test seams.** `CopyDependencies.chunkSize` (a tiny chunk in tests),
  `maxBytesOverride` (a byte-level cap for sub-GiB fixtures) and
  `CopyChunkObserving` (acquire/release around each chunk) exist so the suite
  can prove one-chunk-at-a-time ownership without a flaky RSS measurement.
  `catFileStreaming` is the injected tool seam; the recorded-output doubles use
  a chunking default and the live runner overrides it with the real pipe.

## Requirements

- REQ-0143
- REQ-0144
- REQ-0145
- REQ-0146
- REQ-0147
- REQ-0148
- REQ-0149
