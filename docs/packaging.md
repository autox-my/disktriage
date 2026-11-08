# Packaging: the Homebrew tap

This page is the local packaging procedure. It builds a source tarball, renders
the tap formula against that tarball and verifies the install without
publishing anything. The decisions behind it are
[ADR 0022](adr/0022-homebrew-packaging.md); the plan is
[`diskdoctor.md` §13](../diskdoctor.md#13-naming--distribution).

The signed `.app` is P4 and needs a Developer ID; it is not part of this
procedure.

## What the formula installs

| Piece | Where |
|---|---|
| `disktriage` | `bin/disktriage` (release build) |
| ntfs-3g userspace tools (`ntfsinfo`, `ntfsls`, `ntfscat`, `ntfscluster`, …) | `libexec/ntfs-3g/{bin,sbin}` |
| `smartctl`, `ddrescue` | formula dependencies |

The ntfs-3g tarball is pinned to
`ntfs-3g_ntfsprogs-2026.9.28.tgz`, sha256
`350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8`, and built
with `--disable-ntfs-3g` (no FUSE). The tools are a separate GPL subprocess;
they are not linked into or bundled with `disktriage`.

`dadissent` is deliberately not installed: it is the P0 probe built by
`tools/p0/build-dadissent.sh`, not a user-facing command.

## Build the tarball and the formula

```sh
swift build -c release              # so package.sh reads the real version
scripts/package.sh tarball          # dist/disktriage-<version>.tar.gz + .sha256
scripts/package.sh formula          # dist/disktriage.rb, local file:// url
```

`tarball` archives `HEAD` only (`git archive`), so commit first. `dist/` is
gitignored and is never part of the archive. `formula` replaces the template's
`__DISKTRIAGE_SOURCE_URL__` and `__DISKTRIAGE_SOURCE_SHA256__` with the local
`file://` tarball and its sha256; the checked-in template keeps placeholders
for a release.

The template lives at
[`packaging/homebrew/Formula/disktriage.rb`](../packaging/homebrew/Formula/disktriage.rb).

## Verify locally

```sh
scripts/package.sh verify
```

The command records everything it ran in `dist/verify-report.txt`. In order:

1. `ruby -c dist/disktriage.rb`.
2. `brew tap-new --no-git local/disktriage-test`; copy the generated formula
   into that temporary tap.
3. `brew style` on the formula.
4. `brew audit --strict --formula` (offline; `--online` is the human's later
   check once the real archive exists).
5. `brew install --build-from-source local/disktriage-test/disktriage`.
6. `disktriage --version` and `disktriage check --json`; the `ntfs-3g` row must
   be `PASS` (the overall check exit may be 0, 1 or 3 on a host without Full
   Disk Access).
7. `brew test` (version, check, and `otool -L` over the binary and the four
   tools: no FUSE linkage).
8. `brew uninstall`, `brew untap`, and removal of **only** the dependencies
   this run newly installed. `dist/brew-before.txt` and `dist/brew-after.txt`
   record the lists; `smartmontools` and `ddrescue` are expected to be present
   beforehand and are left alone.

Exit 0 is PASS, 1 is a real finding, 3 means `brew` (or `ruby`) was absent and
the end-to-end install could not run. A grey result is a finding, never a pass.

If a dependency was already installed on the host, it is in the "before" list
and is never touched. If the run installed something new, its name is in
`dist/brew-new-dependencies.txt`.

### Measured on 2026-11-08

`scripts/package.sh verify` exited 0 on this host (macOS 27.2 arm64, Homebrew
7.0.12, Swift 6.4.2). The from-source install passed `brew style`,
`brew audit --strict --formula` (offline), `--version` (`disktriage 0.1.0`),
`brew test` and the `otool -L` no-FUSE check. `check --json` exited 1 because
the host's Full Disk Access row was denied, which is a valid verdict; the
`ntfs-3g` row itself was `PASS`, with all four tools found at
`/opt/homebrew/Cellar/disktriage/0.1.0/libexec/ntfs-3g/bin`. `brew list
--formula` was identical before and after, and the temporary tap, trust entry
and install were removed.

## What the human still has to do

These are outward-facing and are deliberately not done by an agent:

1. ~~Choose the homepage.~~ Done: `https://github.com/autox-my/disktriage`.
2. **Publish the tap repository** `autox-my/homebrew-tap` (users run
   `brew tap autox-my/tap`) and put the formula at `Formula/disktriage.rb`.
   The tap is not published yet; the README says so.
3. **Tag the release** and build the release archive. Replace the template's
   `__DISKTRIAGE_SOURCE_URL__` and `__DISKTRIAGE_SOURCE_SHA256__` with the
   published archive and its real sha256 (or let a release job run
   `scripts/package.sh tarball` and substitute those two values).
4. **Decide the bundle identifier** before the first signed build. It is
   permanent for TCC and is not needed for the CLI-only tap.
5. **P4 only:** sign and notarize the `.app` with a Developer ID, and decide
   whether to ship a bottle. Neither is claimed by this change.
6. `brew audit --strict --formula --online` once the real url exists, since
   the offline audit cannot check the published archive.

The licence is no longer on this list: the project is Apache-2.0 (ADR
[0023](adr/0023-apache-2-0-licence.md)), and the formula declares it.

## Troubleshooting

- **`check` says the ntfs tools are missing after `sudo`.** `sudo` strips
  `DISKTRIAGE_NTFS_PREFIX`; the locator falls back to the resolved
  executable's `../libexec/ntfs-3g`. Run the installed `disktriage`, not a
  copy of it, and check that directory.
- **`otool -L` shows libfuse.** The build used the wrong configure flags. The
  formula passes `--disable-ntfs-3g`; a macFUSE build is out of scope.
- **`brew install` cannot fetch the local tarball.** Re-run
  `scripts/package.sh formula` so the `file://` url points at the current
  `dist/disktriage-<version>.tar.gz`, and check the version matches
  `disktriage --version`.
- **The install touched a disk.** It must not: the formula builds and runs
  the read-only self-test only. `verify` never uses `sudo`, never reads
  `/dev/*` directly and never runs `disktriage image`.
