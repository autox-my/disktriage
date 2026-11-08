# 0025. Continuous integration runs on GitHub-hosted macOS, and never claims the gate

Status: accepted
Date: 2026-11-08

## Context

The repository became public (`github.com/autox-my/disktriage`) and needs a CI
signal on every pull request. Three facts shaped it:

- **The code is macOS-only.** `Package.swift` declares macOS 13, and the guard
  target links `DiskArbitration`/`CoreFoundation` while the CLI and collectors
  use `IOKit` and `hdiutil`. A Linux job would not build the package that ships.
- **The reference toolchain is ahead of the hosted images.** The project is
  developed with full Xcode 27.2 / Swift 6.4.2, but the `macos-26` runner image
  carries Xcode 26.6 as its newest stable release; it is **unknown** whether the
  package builds and tests clean under 26.x. Xcode 27 is available only on the
  `xcode-27` preview image (macOS 27, Xcode 27.2 RC), a preview label that can
  queue and be retired.
- **The gate is not portable yet.** `scripts/check.sh` needs `req`, the author's
  requirement-traceability tool, which is not published. Without `req` the gate
  answers **3** (UNVERIFIABLE) and cannot reach 0. Its rule is also the reason
  the gate may not be approximated: a missing tool is never a pass.

Two risks follow from being public. A self-hosted runner would execute a fork
pull request's code on the owner's machine. A `pull_request_target` workflow
would give that code a write token and secrets. Both are avoidable.

## Decision

**Workflow.** `.github/workflows/ci.yml` triggers on `push` to `main`,
`pull_request` and `workflow_dispatch`, declares `permissions: contents: read`,
holds `concurrency` to cancel a superseded run on the same ref, and sets a
45-minute job timeout. It references no secrets and contains no `sudo` step.
It never uses `pull_request_target`.

**Runners.** GitHub-hosted macOS only: `macos-26` (arm64) for the stable entry,
and the `xcode-27` preview image for an informational entry. No self-hosted
runner, because a public repository's fork pull requests would run code on the
owner's machine. Standard hosted runners are free for public repositories.

**Xcode is selected, not hard-coded.** `.github/scripts/select-xcode.sh` lists
`/Applications/Xcode_*.app`, reads `CFBundleShortVersionString`, and sorts with
`sort -V`. The stable mode drops names carrying `beta`, `RC` or
`Release_Candidate`; the preview mode keeps them. `DEVELOPER_DIR` is exported
through `$GITHUB_ENV`; there is no `xcode-select` and no `sudo`. A runner-image
refresh that adds or removes an Xcode needs no workflow edit.

**What the job asserts.** It installs only what the image lacks (`ddrescue`,
`smartmontools`; `xmllint` ships with macOS), runs `scripts/bootstrap.sh` with
`.build/ntfs-cache` and `.build/ntfs-prefix` cached on the pinned ntfs-3g
sha256, then `swift build` and `swift test --xunit-output`. The test step
applies the gate's own report rule through `scripts/lib/junit-report.sh`: zero
test cases is a failure, and a skipped test is UNVERIFIABLE, which an Actions
job can only encode as a failure with the skipped tests named. A final step
reuses `scripts/lib/temp-leak.sh` to fail on a leaked `disktriage-*` directory.

**The gate runs only when `req` is on `PATH`.** On today's runners it is not,
so the step prints a notice that `scripts/check.sh` did **not** run and exits 0.
The job reports build + test; it does not claim, emulate or relax a gate pass.

**Pinning.** Every third-party action is pinned to a full commit SHA with the
release tag in a trailing comment, and only `actions/checkout`, `actions/cache`
and `actions/upload-artifact` are used.

**The preview entry is informational.** It is `continue-on-error: true` and must
not be a required check; the stable entry is what branch protection may
require.

## Consequences

- A pull request gets a build + test verdict in minutes, and a red run is a
  finding about Xcode 26.x or the code, not about a missing fixture: the
  workflow installs the same dependencies and builds the same fixtures the gate
  needs.
- A green required check means **build + test passed**, not that the tri-state
  gate passed. Until `req` is public, the gate remains a local, human-run step;
  `docs/ci.md` says so in the job's own step notice.
- The package is not built on Linux in CI, by design. If the core ever ships a
  Linux collector, the workflow needs a new job, not a new runner label.
- The `xcode-27` preview entry can be red or unschedulable while the image is a
  preview. `continue-on-error` contains a failing run, but a cancelled or
  unschedulable job is visible to the maintainer; it is not a merge gate.
- A cache hit is a speed-up only: the tarball is sha256-verified each run and a
  restored prefix must carry the pinned version marker, so a stale entry is
  rebuilt rather than trusted. The `-v1` key suffix is the manual bust.
- Fork pull requests run with a read-only token on a disposable hosted runner,
  so a hostile change can waste runner minutes but cannot reach the owner's
  hardware or a secret.

## Requirements

None. This is infrastructure; it adds no claim and changes no gate rule.
