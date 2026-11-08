# Continuous integration

The workflow is [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). It
builds the package and runs the test suite on GitHub-hosted macOS runners, which
are free for public repositories. The decision behind it is ADR
[0025](./adr/0025-continuous-integration.md).

## What runs

| | |
|---|---|
| Triggers | `push` to `main`, every `pull_request`, `workflow_dispatch` |
| Permissions | `contents: read` only; no secrets are referenced anywhere |
| Concurrency | one run per ref; a newer push cancels the superseded run |
| Timeout | 45 minutes for the job, tighter per step |
| Runner | `macos-26` (arm64), plus an informational `xcode-27` preview entry |

One matrix, two entries:

| Check name | Runner | Xcode | Required? |
|---|---|---|---|
| `build + test (macos-26, newest stable Xcode)` | `macos-26` | newest **stable** installed | yes — this is the one to require |
| `build + test (xcode-27 preview, newest Xcode)` | `xcode-27` | newest installed, previews included | no — `continue-on-error: true` |

Each entry runs the same steps:

1. **Checkout** with `persist-credentials: false`; no submodules.
2. **Select Xcode** with [`.github/scripts/select-xcode.sh`](../.github/scripts/select-xcode.sh).
   Nothing is hard-coded: the script lists `/Applications/Xcode_*.app`, reads
   `CFBundleShortVersionString` from each bundle, and sorts with `sort -V`. The
   stable mode drops names carrying `beta`, `RC` or `Release_Candidate`; the
   preview mode keeps them. `DEVELOPER_DIR` is exported through `$GITHUB_ENV`
   — no `xcode-select`, no `sudo`.
3. **Toolchain report**: `xcode-select -p`, `xcodebuild -version`,
   `swift --version`, `sw_vers` — so a run says which toolchain it measured.
4. **Read the ntfs-3g pin** from `scripts/lib/ntfs-3g.sh`, the single source
   `scripts/bootstrap.sh` uses, and key the cache on its sha256.
5. **Cache** `.build/ntfs-cache` (the tarball) and `.build/ntfs-prefix` (the
   built tools). The tarball is sha256-verified on every run and a restored
   prefix must carry the pinned version marker, so a stale cache can be
   rejected but never trusted. Bump the `-v1` suffix in the key to bust it.
6. **Runtime dependencies**, only when missing: `ddrescue` and `smartmontools`
   via Homebrew. `xmllint` ships with macOS and is checked with
   `command -v xmllint`; `libxml2` is installed only if it is absent (its
   `bin` is added to `PATH`, since the formula is keg-only).
7. **`scripts/bootstrap.sh`**: builds the pinned ntfs-3g tools and the
   synthetic NTFS images under `.build/`. No `sudo`, no mount, no `/dev`; the
   only network use is the pinned tarball.
8. **Fixture environment**: `scripts/lib/fixtures.sh` — the same locator the
   gate uses — exports `DISKTRIAGE_NTFS_PREFIX` and `DISKTRIAGE_FIXTURE_DIR`.
9. **`swift build`** and **`swift test --xunit-output .build/test-results/junit.xml`**.
10. **Report rule**: the test step loads `scripts/lib/junit-report.sh`, the
    gate's own reader. Zero test cases is a failure, and a skipped test is
    UNVERIFIABLE, which an Actions job can only express as a failure; the step
    names the skipped tests. The report is uploaded as an artifact when the
    job has failed.
11. **Temp-directory leak check** with `scripts/lib/temp-leak.sh`: the before
    snapshot is taken immediately before the suite, the after snapshot in the
    final step, and `temp_leak_verdict` answers exactly as it does in the gate.
    A hosted runner starts clean, so anything new was left by this run.
12. **Gate, only if `req` is installed**: when `command -v req` succeeds the
    job runs `bash scripts/check.sh` and propagates its exit status. On today's
    runners `req` is not installed, so the step prints a notice that the full
    gate was **not** run and exits 0. The job never claims a gate pass.

Third-party actions are pinned to a full commit SHA with the tag in a trailing
comment; only `actions/checkout`, `actions/cache` and
`actions/upload-artifact` are used.

## What does not run, and why

- **The full gate.** `scripts/check.sh` needs `req`, the author's
  requirement-traceability tool, which is not published yet, and the
  requirement steps answer UNVERIFIABLE without it. A private tool cannot be
  installed from CI, and faking its answer would make the gate lie, so the
  workflow reports **build + test** and says so. `req` is neither stubbed nor
  silently skipped: its absence is printed as a notice on the run.
- **Linux.** `Package.swift` declares macOS 13 and the guard links
  `DiskArbitration`/`CoreFoundation`; the CLI and collectors use `IOKit` and
  `hdiutil`. A Linux job would need a different package row, not a different
  runner label.
- **Root, Full Disk Access, a physical disk, or the network.** The suite reads
  synthetic NTFS images generated under `.build/`, fakes the hardware seams, and
  has no privileged step; the only download is the pinned, sha256-verified
  ntfs-3g tarball.
- **A self-hosted runner.** This is a public repository: a fork pull request
  would execute contributor code on the owner's machine. Hosted runners are
  disposable and free for public repositories.

## Toolchain caveat

The project's reference toolchain is full Xcode 27.2 / Swift 6.4.2 (AGENTS.md).
The `macos-26` image currently carries Xcode 26.6 as its newest stable release;
it is **unknown** whether the package builds and tests clean under 26.x — that
is exactly what the stable job measures, and a red run is a finding to report,
not something to paper over. Xcode 27.2 is available on the `xcode-27` preview
image (macOS 27, Xcode 27.2 RC); that entry is informational because preview
images are not stable, can queue, and may be retired when the image graduates.

The `xcode-27` label is a GitHub-hosted preview image, not a self-hosted
runner; `.github/actionlint.yaml` declares it only because actionlint's label
table predates it.

## Running the same steps locally

```sh
brew install ddrescue smartmontools      # only the missing ones
scripts/bootstrap.sh                     # pinned ntfs-3g + synthetic images
swift build
mkdir -p .build/test-results
swift test --xunit-output .build/test-results/junit.xml
bash scripts/check.sh                    # the full gate, needs req + xmllint
```

`scripts/check.sh` exports the fixture variables itself, so the two commands
agree with CI without any extra environment. To pick Xcode the way CI does:

```sh
app="$(.github/scripts/select-xcode.sh stable)"   # or: newest
DEVELOPER_DIR="$app/Contents/Developer" swift build
```

The selection script is exercised without an Xcode install by pointing
`XCODE_APP_DIR` at a directory of fake `Xcode*.app` bundles.

Lint the workflow with [`actionlint`](https://github.com/rhysd/actionlint):

```sh
brew install actionlint
actionlint .github/workflows/ci.yml
```

`.github/actionlint.yaml` lists the `xcode-27` preview label because
actionlint's built-in label table does not know it yet; the label is a
GitHub-hosted image, not a self-hosted runner.

## Fork pull requests

- The trigger is `pull_request`, never `pull_request_target`: a fork's code runs
  in the context of the merge commit, with the workflow's `contents: read`
  token and no secrets, because the workflow references none.
- `persist-credentials: false` keeps the token out of `.git/config`, and no step
  needs `sudo` or a write permission.
- GitHub may hold the first run from a first-time contributor for maintainer
  approval. Everything after that is the same workflow as a maintainer branch.
- Because the runner is GitHub-hosted, a fork does not get near the owner's
  hardware.

## Required checks

In *Settings → Branches → Branch protection*, require:

```
build + test (macos-26, newest stable Xcode)
```

Do **not** require the `xcode-27 preview` entry: it is `continue-on-error` and
may be red or unavailable while the image is a preview. The stable check name
carries the matrix name verbatim, so renaming the matrix entry renames the
required check — update both together.

Until `req` is public the gate cannot be a required check; requiring this job
means requiring **build + test**, not the tri-state gate. The distinction is
deliberate: a green check here is not a statement that the gate passed.
