# disktriage

`disktriage` triages a failing disk from the hardware signals macOS exposes,
images it with `ddrescue`, and hands off. It never mounts the source device:
triage reads signals only, and inspection/copy happen on the image. If a volume
will not mount, stop, read the signals, image the device, and only then touch a
filesystem.

**Status: alpha.** The tool is usable on the cases it was built for, but it is
not a general-purpose recovery suite.

## Safety stance and limits

- **Never mount the source device.** The mount guard exists because macOS
  automounts; inspection and copy read an image, never the failing disk.
- **Insufficient evidence is a verdict** (exit 20). "Healthy" is not a verdict
  this tool can issue, and an absent signal is never a zero.
- **Reads only until you ask for a write.** Writes target an image or a copy
  destination; the only NTFS write is an explicit boot-sector restore on a
  copy.
- **Alpha hardware coverage.** Hardware-tested on two drives only (the MiNaH
  recovery and one control disk), not a broad matrix.
- **SMART is often unreachable over USB.** Most USB bridges hide it on macOS;
  the tool says so and falls back to kernel-log and I/O evidence rather than
  inventing a verdict.
- **Imaging is slow on USB 2.** A generic USB 2 bridge measured about 37 MB/s
  on clean zones; a failing drive is slower still.
- **Inspect/copy cover NTFS and the native filesystems.** NTFS uses the
  ntfs-3g userspace tools; APFS, HFS+, exFAT and FAT images are attached
  read-only with `diskutil image attach --noMount --readOnly` and mounted
  read-only with `diskutil mount readOnly nobrowse`. No root is needed. A
  locked encrypted volume is refused rather than prompting for a passphrase.
  Per-file damage attribution is NTFS-only; the native filesystems report
  damage at volume level (see ADR 0025).

Exit codes and their precedence are in
[`diskdoctor.md` §5](diskdoctor.md#exit-codes). The short version: 0 no
actionable fault, 10–13 a diagnosed fault, 20 insufficient evidence, 21/30 no
verdict can be formed (usage errors are 2).

## Install

The v1 distribution route is a Homebrew tap. It is **not published yet**, so
the commands below will work once `autox-my/homebrew-tap` exists:

```sh
brew tap autox-my/tap
brew install disktriage
```

The tap installs `disktriage`, the ntfs-3g userspace tools under its own
`libexec`, and declares `ddrescue` and `smartmontools` as dependencies. The
signed `.app` is future work.

## Build from source

Requirements: macOS 13 or newer, Xcode 27.2 / Swift 6.4.2, Homebrew, and the
runtime dependencies:

```sh
brew install ddrescue smartmontools
git clone https://github.com/autox-my/disktriage
cd disktriage
scripts/bootstrap.sh      # ntfs-3g prefix + synthetic NTFS and native fixtures
swift build
bash scripts/check.sh     # 0 PASS, 1 FAIL, 3 UNVERIFIABLE
```

The gate also needs `xmllint` and `req`, the author's requirement-traceability
tool, which is **not publicly available yet**. A missing tool is UNVERIFIABLE
(3) with a message, never a pass, so without `req` the gate cannot reach 0.
`swift build` and `swift test` do not need it.

`scripts/bootstrap.sh` is the one documented setup command. It builds the
pinned ntfs-3g tools and the live-test images under `.build/`, is idempotent,
uses no `sudo`, attaches only the synthetic images it just created (in the
fixture generator, then unmounts and ejects them) and never names a physical
device. Without it the gate answers **3** and names the script; it does not
skip to green.

## Documentation

- Plan, scope and exit codes: [`diskdoctor.md`](diskdoctor.md)
- SDLC, the gate and the TDD loop: [`docs/sdlc.md`](docs/sdlc.md)
- Decisions (ADRs): [`docs/adr/README.md`](docs/adr/README.md)
- Homebrew packaging: [`docs/packaging.md`](docs/packaging.md)
- NTFS inspection spike: [`docs/ntfs-spike.md`](docs/ntfs-spike.md)
- Requirement traceability: [`docs/req-workflow.md`](docs/req-workflow.md)

## Licence

Apache-2.0; see [`LICENSE`](LICENSE). `disktriage` invokes the GPL tools
`ddrescue`, `smartmontools` and `ntfs-3g` as separate processes; it does not
link or bundle them. See [`NOTICE`](NOTICE).

## Contributing

Run `bash scripts/check.sh` before handing back. The gate is tri-state: 0 PASS,
1 FAIL, 3 UNVERIFIABLE — and a skipped test is 3, never a pass. TDD is
mandatory for code: write the failing test at the public seam first, then the
implementation. New obligations are `claims/REQ-NNNN.yml` files, and a test
carries the `REQNNNN` tag in its function name so the JUnit report can link it.
See [`docs/sdlc.md`](docs/sdlc.md) and
[`docs/req-workflow.md`](docs/req-workflow.md).
