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
        .executable(name: "disktriage", targets: ["disktriage"]),
    ],
    targets: [
        .target(
            name: "DiskTriageCore",
            path: "Sources/DiskTriageCore"
        ),
        .target(
            name: "DiskTriageCLI",
            dependencies: ["DiskTriageCore"],
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
            dependencies: ["DiskTriageCLI"],
            path: "Tests/DiskTriageCLITests"
        ),
    ]
)
