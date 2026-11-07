import Foundation

/// The one distribution version. `disktriage --version` and `disktriage version`
/// print it; `scripts/package.sh` asks the built binary, so the tarball name,
/// the formula's `version` and the CLI cannot drift. The number is pre-1.0
/// until the P4 signed app ships (docs/adr/0022-homebrew-packaging.md).
public enum DisktriageVersion {
    public static let current = "0.1.0"
}
