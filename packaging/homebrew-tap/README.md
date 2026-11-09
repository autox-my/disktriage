# autox-my Homebrew tap

Homebrew formulae for [disktriage](https://github.com/autox-my/disktriage).
The tap lives at `github.com/autox-my/homebrew-tap`; this directory is its
scaffold.

```sh
brew tap autox-my/tap
brew install disktriage
```

## Status: no formula yet

`Formula/` is deliberately empty. The formula is generated from a tagged
release's source tarball and attached to that release; a human then copies it
into `Formula/disktriage.rb` here. Until the first release and that copy,
`brew tap autox-my/tap` has nothing to install.

The tap's own CI (`.github/workflows/tests.yml`) runs `brew style` and
`brew audit --strict --online` on changed formulae. With `Formula/` empty it
says so and passes — it does not pretend a formula was checked.

## What the formula installs

| Piece | Where |
|---|---|
| `disktriage` | `bin/disktriage`, built from source by Homebrew |
| ntfs-3g userspace tools (`ntfsinfo`, `ntfsls`, `ntfscat`, `ntfscluster`, …) | `libexec/ntfs-3g/`, built `--disable-ntfs-3g` (no FUSE) |
| `ddrescue`, `smartmontools` | declared formula dependencies |

macOS 13 (Ventura) or newer. The GPL tools are separate subprocesses, not
linked into or bundled with `disktriage`.

## Licence

Apache-2.0. See [LICENSE](https://github.com/autox-my/disktriage/blob/main/LICENSE)
in the main repository.
