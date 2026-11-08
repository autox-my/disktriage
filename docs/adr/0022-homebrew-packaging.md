# 0022. Homebrew tap packaging

Status: accepted
Date: 2026-11-08

## Context

`diskdoctor.md` §13 chooses a Homebrew tap as the first distribution route; a
signed `.app` is P4 and needs a Developer ID, so it is out of scope here. The
tap has to deliver a command that already works on this Mac: `triage` needs
`smartctl`, `image` needs `ddrescue`, and `inspect` / `copy` need the ntfs-3g
userspace tools. The core `ntfs-3g` formula is Linux-only and the tap variant
requires macFUSE (`docs/ntfs-spike.md`, "How to build"), so the tools must be
built from the pinned upstream tarball with the FUSE driver disabled.

A plain Homebrew install puts `bin/disktriage` in a keg and symlinks it into
the prefix. The ntfs-3g tools live under the keg's `libexec`, which is not on
`PATH`; `sudo` also strips `DISKTRIAGE_NTFS_PREFIX`. A lookup that only used
the environment would therefore report a working install as missing.

The repository had no `LICENSE` file when this record was written. That was a
blocker for publication, not something a packaging change could invent; it is
now resolved: the project is Apache-2.0 (ADR
[0023](./0023-apache-2-0-licence.md)).

## Decision

**Version.** `DisktriageVersion.current` in `DiskTriageCore` is the one
version string. `disktriage --version` and `disktriage version` print
`disktriage <version>` on stdout, write nothing to stderr and exit 0.
`scripts/package.sh` asks the built binary, so the tarball name, the formula's
inferred version and the CLI cannot drift.

**Tool lookup.** `NTFSToolLocator` searches, in order:

1. `DISKTRIAGE_NTFS_PREFIX` (`bin/`, `sbin/`, the prefix itself);
2. the resolved executable's `../libexec/ntfs-3g/bin` and `.../sbin`;
3. `PATH`;
4. `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/sbin`.

The executable path is injected. The live callers pass
`Bundle.main.executablePath`; tests build a keg and a `bin/disktriage` symlink
under `TempDir` and pass that path, so no test needs a real brew. Symlink
resolution is part of the rule: without it the parent of
`/opt/homebrew/bin/disktriage` is `/opt/homebrew`, not the keg.

**Policy.** `CommandPolicy` still accepts an ntfs tool only as an absolute
path whose basename is one of `ntfsinfo`, `ntfsls`, `ntfscat`, `ntfscluster`
(inspect) or the version allow-list (check). There is no directory or prefix
wildcard; the located path is the path that is checked.

**Formula.** `packaging/homebrew/Formula/disktriage.rb`:

- declares `smartmontools` and `ddrescue` as runtime dependencies, macOS 13 or
  newer (matching `Package.swift`) and Xcode 16 for the Swift 6 toolchain;
- pins `ntfs-3g_ntfsprogs-2026.9.28.tgz` by sha256 and builds only its
  userspace tools with `--disable-ntfs-3g --disable-shared --enable-static`
  into `libexec/ntfs-3g`, with `ac_cv_header_libintl_h=no` so Homebrew's
  gettext header cannot make the static link want `libintl`; no libfuse is
  looked for, linked or bundled;
- builds the Swift package with `swift build -c release --disable-sandbox`
  and installs only `bin/disktriage`. `dadissent` is a P0 probe built by
  `tools/p0/build-dadissent.sh`; it is not a user-facing product and is not
  installed;
- its `test do` runs `--version`, runs `check --json` (exit 0, 1 or 3 are all
  valid verdicts because a host may lack Full Disk Access, but the ntfs-3g
  row must be PASS) and runs `otool -L` over the binary and the four tools to
  prove no FUSE linkage.

The GPL tools remain a separate subprocess built from source on the user's
machine; nothing GPL is linked into or bundled with the disktriage binary.
The formula comment states this.

**Source url.** The formula template keeps `__DISKTRIAGE_SOURCE_URL__` and
`__DISKTRIAGE_SOURCE_SHA256__`. `scripts/package.sh formula` substitutes the
local `file://` tarball and its sha256 for verification. The template's checked
in values are placeholders for a release; the human fills the published
archive. `homepage` is the placeholder
`https://github.com/autox-my/disktriage` until the human decides the
public home.

**Licence.** The project is Apache-2.0 (ADR
[0023](./0023-apache-2-0-licence.md)); the formula declares
`license "Apache-2.0"` and no longer uses `:cannot_represent`.

**Script.** `scripts/package.sh` has `tarball`, `formula` and `verify`.
`tarball` is `git archive HEAD` (never a dirty tree), `formula` substitutes
the local url and sha256, and `verify` runs `ruby -c`, `brew style`,
`brew audit --strict --formula` (offline), a from-source install in a
temporary tap, the formula test, the otool check, then uninstalls the formula,
untaps and removes only dependencies that run newly installed. It records
`dist/verify-report.txt` and the brew lists. It does not push, tag, publish a
tap or sign anything.

## Consequences

- `check` reports `ntfs-3g` PASS from the installed libexec, and the missing
  tools messages name that location.
- Tests: `REQ0248_versionIsSingleSourced`,
  `REQ0249_executableRelativeLibexecOrder`,
  `REQ0250_selfTestFindsInstalledLibexec`,
  `REQ0251_libexecPathIsAllowListed`. The lookup order and symlink
  resolution were mutation-checked: moving the libexec block after `PATH`, or
  dropping `resolvingSymlinksInPath`, turns the locator test red.
- No bottle is claimed and no tap is published. The signed `.app`, the
  bundle identifier and the homepage remain human decisions, as does filling
  the real url/sha256 and tagging a release.
- `scripts/package.sh verify` downloads the ntfs-3g tarball through Homebrew;
  its sha256 is the pinned value above. Homebrew itself may refresh metadata,
  which this repository does not control.

## Requirements

- REQ-0248
- REQ-0249
- REQ-0250
- REQ-0251
- REQ-0252
- REQ-0253
- REQ-0254
- REQ-0255
- REQ-0256
