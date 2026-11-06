// swift-tools-version: 6.0
import PackageDescription

// DiskDoctor: a portable core (no OS calls) plus thin platform front ends.
// The classifier is a pure function over a SignalSet; collectors live outside
// this package's core target. See diskdoctor.md §3 and docs/sdlc.md.
let package = Package(
    name: "DiskDoctor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskDoctorCore", targets: ["DiskDoctorCore"]),
        .executable(name: "diskdoctor", targets: ["diskdoctor"]),
    ],
    targets: [
        .target(
            name: "DiskDoctorCore",
            path: "Sources/DiskDoctorCore"
        ),
        .executableTarget(
            name: "diskdoctor",
            dependencies: ["DiskDoctorCore"],
            path: "Sources/diskdoctor"
        ),
        // An executable, not a `.testTarget`: this toolchain (/usr/bin/swift
        // from the Command Line Tools) ships without XCTest and without Swift
        // Testing, so `swift test` cannot execute a suite here. The runner is
        // dependency-free and invoked by scripts/check.sh. See docs/sdlc.md.
        .executableTarget(
            name: "DiskDoctorCoreTests",
            dependencies: ["DiskDoctorCore"],
            path: "Tests/DiskDoctorCoreTests"
        ),
    ]
)
