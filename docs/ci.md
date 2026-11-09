# Continuous integration

Two workflows:

- [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) — build, test and
  the full gate on every push and pull request.
- [`.github/workflows/release.yml`](../.github/workflows/release.yml) — the
  release, triggered only by pushing a tag `v*.*.*`.

Both run on GitHub-hosted macOS runners, which are free for public
repositories. The decisions behind them are ADR
[0025](./adr/0025-continuous-integration.md) (the runner and the honest-job
rule) and ADR [0029](./adr/0029-gate-required-in-ci-and-tagged-releases.md)
(`req` is public, so the gate is required, and releases are cut from a tag).

## What runs in CI

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
6. **Cache** `~/.cargo/bin`, `~/.cargo/registry` and `~/.cargo/git`. The key
   hashes `.github/scripts/req.sh`, the one file holding the `req` pin, so a
   pin change busts the cache. A restored `req` is checked against the pin
   before it is used, so a stale binary is rebuilt, never trusted.
7. **Runtime dependencies**, only when missing: `ddrescue` and `smartmontools`
   via Homebrew. `xmllint` ships with macOS and is checked with
   `command -v xmllint`; `libxml2` is installed only if it is absent (its
   `bin` is added to `PATH`, since the formula is keg-only).
8. **`scripts/bootstrap.sh`**: builds the pinned ntfs-3g tools and the
   synthetic NTFS/native fixture images under `.build/`. No `sudo`, no mount of
   a physical device, no `/dev`; the only network use is the pinned tarball.
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
12. **Install `req` at the pinned commit** (below), **probe the gate's script
    rules** with `scripts/check-gate-probe.sh` (faked reports, leaked temp
    state, the requirement steps, the release formula renderer and the req
    pin), then **`bash scripts/check.sh`** as the gate. Exit **0** passes;
    **anything else fails the job**. An exit **3** is annotated as
    UNVERIFIABLE so the run says which third state it hit rather than
    reporting a bare failure. The gate is not conditional on a tool being
    present: a missing `req`, `xmllint` or fixture is a failure of this job,
    never a silent pass.

Third-party actions are pinned to a full commit SHA with the tag in a trailing
comment; only `actions/checkout`, `actions/cache` and
`actions/upload-artifact` are used.

## The `req` pin

`req` is the requirement-traceability tool the gate runs. It is public
(`github.com/autox-my/req`, Apache-2.0) but publishes **no prebuilt release**,
so a commit is the provenance.

The pin lives in exactly one place: [`.github/scripts/req.sh`](../.github/scripts/req.sh),
as a full 40-character commit. Both workflows source it and call
`req_install`; nothing else names a revision.

```
REQ_REV = f871f80e22807fc8db6c1b9e6ee7b49c45197910
```

The install is a source build, using the Cargo that ships in the `macos-26`
runner image (the image README lists Rust 1.98.0, Cargo 1.98.0 and rustup
1.29.0):

```sh
cargo install --git https://github.com/autox-my/req.git \
  --rev f871f80e22807fc8db6c1b9e6ee7b49c45197910 --locked --root "$HOME/.cargo" req
```

The trailing `req` is the package name, not decoration: at this revision the
repository carries three binaries (`req`, `req-paraphrase`, `req-tier2`), and an
install with no package selection fails with *"multiple packages with binaries
found"*. That is a limitation of the install line in `req`'s own README, not a
pin choice; `req.sh` carries the working command.

`req --version` prints `built from <short sha>`. `req_install` refuses a binary
that does not report the pinned short sha, so a `req` already on `PATH` from a
different commit cannot answer for this one. If `cargo` is missing the step
fails; it never skips the gate.

Measured on 2026-11-09 with a build from this rev:

- `req --version` → `req 0.1.0`, `built from f871f80`;
- `req --root . canon --fail-on-flag` on this corpus → exit 0, *"315 claims
  (0 unstructured); pins: 282 on 241 claim(s), 0 flagged"*.

Bumping the pin is a normal change: edit the sha in `req.sh`, let the cache key
follow it, and run the gate locally with `REQ_BIN` pointing at the new build.

## What does not run, and why

- **Linux.** `Package.swift` declares macOS 13 and the guard links
  `DiskArbitration`/`CoreFoundation`; the CLI and collectors use `IOKit` and
  `hdiutil`. A Linux job would need a different package row, not a different
  runner label.
- **Root, Full Disk Access, a physical disk, or the network.** The suite reads
  synthetic NTFS/native images generated under `.build/`, fakes the hardware
  seams, and has no privileged step; the only downloads are the pinned,
  sha256-verified ntfs-3g tarball and the pinned `req` source.
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

## The release workflow

`.github/workflows/release.yml` is triggered **only** by pushing a tag
matching `v*.*.*`, declares `permissions: contents: write` and nothing else,
and does not cancel an in-flight release. It:

1. checks the tag is exactly `v<DisktriageVersion.current>` (and that the tag
   has the `v<major>.<minor>.<patch>` shape) — before anything expensive runs;
2. selects Xcode, installs the missing runtime dependencies, builds the
   fixtures, installs `req` at the pin;
3. runs the full gate and stops on anything but exit 0 — no release is cut
   from a red or UNVERIFIABLE tree;
4. builds the release binary and `scripts/package.sh tarball`, which archives
   `HEAD` (the tagged commit) and writes the `.sha256`;
5. creates the GitHub Release with `gh release create`, attaching the tarball
   and its `.sha256`; a pre-existing release is an error, never an overwrite;
6. renders the formula for the release asset URL
   (`scripts/package.sh formula --url https://github.com/<owner>/<repo>/releases/download/<tag>/disktriage-<version>.tar.gz`),
   prints it to the log, attaches it to the release with `gh release upload`,
   and uploads it as the workflow artifact `formula-<tag>`.

7. It does **not** push to the tap. That needs a token the human has not
   created; the formula travels as a release asset instead. Copying it into
   `autox-my/homebrew-tap/Formula/disktriage.rb` is the human step in
   [`docs/packaging.md`](./packaging.md#what-the-human-still-has-to-do).

Nothing is released by merging this workflow, and a tag push is a deliberate
act. Do not re-run a failed release without deciding what to do with the
release it may already have created.

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
agree with CI without any extra environment. To install `req` exactly as CI
does:

```sh
. .github/scripts/req.sh
req_install
bash scripts/check.sh
```

To pick Xcode the way CI does:

```sh
app="$(.github/scripts/select-xcode.sh stable)"   # or: newest
DEVELOPER_DIR="$app/Contents/Developer" swift build
```

The selection script is exercised without an Xcode install by pointing
`XCODE_APP_DIR` at a directory of fake `Xcode*.app` bundles.

Lint the workflows with [`actionlint`](https://github.com/rhysd/actionlint):

```sh
brew install actionlint
actionlint .github/workflows/ci.yml .github/workflows/release.yml \
  packaging/homebrew-tap/.github/workflows/tests.yml
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
- The release workflow is `push: tags` only. A fork pull request cannot trigger
  it, and its `contents: write` token exists only for a tag push in this
  repository.
- Because the runner is GitHub-hosted, a fork does not get near the owner's
  hardware.

## Required checks

In *Settings → Branches → Branch protection*, require:

```
build + test (macos-26, newest stable Xcode)
```

That check now includes the full gate. Do **not** require the `xcode-27
preview` entry: it is `continue-on-error` and may be red or unavailable while
the image is a preview. The stable check name carries the matrix name
verbatim, so renaming the matrix entry renames the required check — update both
together.
