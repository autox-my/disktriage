# 0029. The gate is a required CI check, and a tag cuts the release

Status: accepted
Date: 2026-11-09

## Context

ADR [0025](0025-continuous-integration.md) put CI on GitHub-hosted macOS and
deliberately did **not** claim a gate pass: `req`, the requirement-traceability
tool the gate runs, was not published, and a job cannot fake a tool it does
not have. That record's runner, permission and pinning decisions still hold.
Three things changed:

- **`req` is public.** `github.com/autox-my/req` is Apache-2.0 and publishes no
  prebuilt release. A commit is the provenance, and `req --version` prints
  `built from <short sha>`.
- **A pin was measured, not assumed.** Current `req` main is
  `f871f80e22807fc8db6c1b9e6ee7b49c45197910`. A build from that rev reports
  `built from f871f80`, and `req --root . canon --fail-on-flag` on this corpus
  exits 0 (`315 claims (0 unstructured); pins: 282 on 241 claim(s), 0 flagged`).
  The corpus is not changed by this decision.
- **Cargo is on the runner.** The `macos-26` runner-image README lists Rust
  1.98.0, Cargo 1.98.0 and rustup 1.29.0, so a source install needs no setup
  action.

One fact the pin forced: the install line `req` documents,
`cargo install --git <repo> --rev <rev> --locked`, **fails** at this revision.
The repository carries three binaries (`req`, `req-paraphrase`, `req-tier2`),
and cargo refuses an ambiguous package selection: *"multiple packages with
binaries found: req, req-paraphrase, req-tier2"*. Naming the package
(`… --locked req`) succeeds. That is a finding about `req`'s README, recorded
here so the working command is not re-derived from a red CI run.

The release side had the same honesty problem in the other direction:
`docs/packaging.md` said a human must replace the formula's placeholders with
the published archive and its sha256, but nothing produced that archive on a
tag, so the two values could drift from the tag they claimed to describe.

## Decision

**One pin, one file.** [`.github/scripts/req.sh`](../.github/scripts/req.sh)
holds `REQ_REV` as a full 40-character commit and the `req_install` function.
Both workflows source it; no workflow and no document holds a second copy. The
install is:

```sh
cargo install --git https://github.com/autox-my/req.git \
  --rev f871f80e22807fc8db6c1b9e6ee7b49c45197910 --locked --root "$HOME/.cargo" req
```

`req_install` accepts a binary only when `req --version` reports
`built from f871f80`; a stale `req` on `PATH` is rebuilt, and a missing
`cargo` fails the step. There is no skip path. The workflow caches
`~/.cargo/bin`, `~/.cargo/registry` and `~/.cargo/git` with the already-pinned
`actions/cache`, keyed by `hashFiles('.github/scripts/req.sh')`, so changing
the pin busts the cache and a restored binary is still provenance-checked.

**CI runs the gate and requires 0.** In
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml), the stable
`macos-26` entry installs `req` and then runs `bash scripts/check.sh`; exit 0
passes, and every other exit fails the job. Exit 3 (UNVERIFIABLE) is annotated
as such because Actions has only two states, but it fails: a grey result is a
finding, not a pass. The `xcode-27` preview entry keeps `continue-on-error:
true` and is not a required check. Branch protection still requires the
`build + test (macos-26, newest stable Xcode)` check, which now includes the
gate.

**A tag cuts the release, and only a tag.**
[`.github/workflows/release.yml`](../.github/workflows/release.yml) triggers on
`push` of `v*.*.*`, with `permissions: contents: write` and no other
permission, and `cancel-in-progress: false`. It:

1. rejects a tag that is not `v<major>.<minor>.<patch>` or does not equal
   `v<DisktriageVersion.current>`, before any build;
2. builds fixtures and the pinned `req`, then runs `bash scripts/check.sh` and
   stops on every exit but 0;
3. runs `swift build -c release` and `scripts/package.sh tarball` (which
   archives `HEAD`, the tagged commit);
4. refuses a tag whose release already exists, then `gh release create`s the
   release with the tarball and its `.sha256`;
5. renders the formula for the release-asset URL through
   `scripts/package.sh formula --url <asset>`, prints it, attaches it to the
   release with `gh release upload`, and uploads it as the run artifact
   `formula-<tag>`.

**`scripts/package.sh formula --url` is the release renderer.** The sha256
still comes from the local, gated tarball; only the URL changes. The url and
digest are validated before the version lookup: `http(s)` only, 64 lowercase
hex characters, both template tokens present, and no placeholder may survive.
`scripts/check-gate-probe.sh` drives the same renderer with fake templates and
proves each rule bites, so the checks do not need a release build.

**No automatic tap push.** Publishing to `autox-my/homebrew-tap` needs a
`TAP_TOKEN` the human has not created, and this repository's
`contents: write` token is scoped to this repository. The formula therefore
travels as a release asset; copying it into the tap is a human step in
`docs/packaging.md`. The tap itself is scaffolded at
`packaging/homebrew-tap/` (README, its own `brew style` +
`brew audit --strict --online` workflow on changed formulae, and an empty
`Formula/`) but is not published, and the real formula must not be committed
there before a release exists.

## Consequences

- A pull request is green only when the gate answered 0 on the stable runner.
  The job no longer prints a "gate not run" notice because it now installs
  what the gate needs; a missing `cargo`, `req`, `xmllint` or fixture is a red
  job.
- The gate is slower on CI: it builds and tests once on its own steps and once
  inside `scripts/check.sh`. That duplication is the cost of keeping the
  gate's own evidence intact rather than re-implementing its steps in YAML.
- The `req` README's install line is wrong at this rev. Reporting it upstream
  is a separate act; this repository records the working form and the reason.
- The pin is a full commit, not a tag or branch, and it is written down in one
  file. Moving it is a reviewable one-line change plus a warm-from-cold cargo
  build.
- `req canon` exit 0 is not a release verdict: it judges pins only. The gate's
  own `req gate` step still judges linked tests and undecided claims, and it is
  what the release workflow requires.
- A release cannot be re-cut by re-running the workflow: an existing release
  is an error. `gh release delete <tag>` is a deliberate human act, not a retry
  path.
- Nothing is released by this change and the tap is not published. The README,
  `docs/packaging.md` and `docs/ci.md` say so; no command here claims a release
  exists.
- The tap workflow lives in `packaging/homebrew-tap/` and only runs once that
  directory is published as the tap repository; until then this repository's
  CI does not run it. `.github/actionlint.yaml` needs no new label: both
  workflows use `macos-26`.
- The release workflow cannot be exercised locally end to end. Its tag check,
  package and formula steps use the same scripts and probes the gate covers,
  but the GitHub Release and artifact steps are only measured by pushing a tag,
  which this change does not do.

## Requirements

None. This is infrastructure; it adds no claim and changes no gate rule.
