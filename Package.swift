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
        .executableTarget(
            name: "disktriage",
            dependencies: ["DiskTriageCore"],
            path: "Sources/disktriage"
        ),
        // An executable, not a `.testTarget`: this toolchain (/usr/bin/swift
        // from the Command Line Tools) ships without XCTest and without Swift
        // Testing, so `swift test` cannot execute a suite here. The runner is
        // dependency-free and invoked by scripts/check.sh. See docs/sdlc.md.
        .executableTarget(
            name: "DiskTriageCoreTests",
            dependencies: ["DiskTriageCore"],
            path: "Tests/DiskTriageCoreTests"
        ),
    ]
)
