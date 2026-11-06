import Foundation

/// Entry point for `swift run DiskDoctorCoreTests`.
///
/// Output is TAP-like and ends with `Executed N tests, M failures`;
/// `scripts/check.sh` fails closed when that line is missing or N is zero.
var executed = 0
var failed = 0

@MainActor
func test(_ name: String, _ body: () throws -> Void) {
    executed += 1
    do {
        try body()
        print("ok \(executed) - \(name)")
    } catch {
        failed += 1
        print("not ok \(executed) - \(name)")
        print("  \(error)")
    }
}

signalSetTests()
exitCodeTests()

print("Executed \(executed) tests, \(failed) failures")
if failed > 0 { exit(1) }
