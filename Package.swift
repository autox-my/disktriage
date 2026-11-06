// swift-tools-version: 6.0
import PackageDescription

// disktriage: a portable core (no OS calls) plus thin platform front ends.
// The classifier is a pure function over a SignalSet; collectors live outside
// this package's core target. See diskdoctor.md §3 and docs/sdlc.md.
let package = Package(
    name: "disktriage",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskTriageCore", targets: ["DiskTriageCore"]),
        .library(name: "DiskTriageGuard", targets: ["DiskTriageGuard"]),
        // The P0 row-5 probe is now a thin entry point over DiskTriageGuard,
        // so tools/p0/build-dadissent.sh builds the same code `guard` uses.
        .executable(name: "dadissent", targets: ["dadissent"]),
        .executable(name: "disktriage", targets: ["disktriage"]),
    ],
    targets: [
        .target(
            name: "DiskTriageCore",
            path: "Sources/DiskTriageCore"
        ),
        .target(
            name: "DiskTriageCLI",
            dependencies: ["DiskTriageCore", "DiskTriageCollectors", "DiskTriageGuard"],
            path: "Sources/DiskTriageCLI"
        ),
        .executableTarget(
            name: "disktriage",
            dependencies: ["DiskTriageCore", "DiskTriageCLI"],
            path: "Sources/disktriage"
        ),
        // A regular test target: full Xcode (27.2, Swift 6.4.2) ships Swift
        // Testing, and the default `swiftbuild` engine builds and runs it.
        // The old dependency-free runner and the `native` pin are gone because
        // both workarounds were measured unnecessary, not because they were
        // inconvenient. See docs/sdlc.md.
        .testTarget(
            name: "DiskTriageCoreTests",
            dependencies: ["DiskTriageCore"],
            path: "Tests/DiskTriageCoreTests"
        ),
        .testTarget(
            name: "DiskTriageCLITests",
            dependencies: ["DiskTriageCLI", "DiskTriageCollectors", "DiskTriageCore", "DiskTriageGuard"],
            path: "Tests/DiskTriageCLITests"
        ),
        // P1c: the collector framework. OS calls, subprocesses and filesystem
        // reads live here, never in DiskTriageCore (diskdoctor.md §3).
        .target(
            name: "DiskTriageCollectors",
            dependencies: ["DiskTriageCore"],
            path: "Sources/DiskTriageCollectors"
        ),
        .testTarget(
            name: "DiskTriageCollectorsTests",
            dependencies: ["DiskTriageCollectors", "DiskTriageCore"],
            path: "Tests/DiskTriageCollectorsTests"
        ),
        // P3a: the mount guard. macOS-only, and the decision logic is pure so
        // the suite needs neither DiskArbitration nor a disk.
        .target(
            name: "DiskTriageGuard",
            path: "Sources/DiskTriageGuard",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(
            name: "DiskTriageGuardTests",
            dependencies: ["DiskTriageGuard"],
            path: "Tests/DiskTriageGuardTests"
        ),
        .executableTarget(
            name: "dadissent",
            dependencies: ["DiskTriageGuard"],
            path: "Sources/dadissent"
        ),
    ]
)
