import Foundation

/// Assertion support for the dependency-free test runner.
///
/// This toolchain (`/usr/bin/swift` from the Command Line Tools) ships without
/// XCTest and without Swift Testing, so `swift test` cannot execute a suite on
/// this machine. The runner keeps the expectations in one place and prints a
/// summary that `scripts/check.sh` parses; migrating to XCTest later is a
/// mechanical rewrite of these helpers, not of the tests.

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func failure(_ message: String, file: StaticString, line: UInt) -> TestFailure {
    TestFailure(description: "\(message) [\(file):\(line)]")
}

func expect(
    _ condition: Bool,
    _ what: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if !condition { throw failure(what(), file: file, line: line) }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ what: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if actual != expected {
        throw failure("\(what()): expected \(expected), got \(actual)", file: file, line: line)
    }
}

func expectNil<T>(
    _ actual: T?,
    _ what: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if let actual {
        throw failure("\(what()): expected nil, got \(actual)", file: file, line: line)
    }
}

func require<T>(
    _ actual: T?,
    _ what: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws -> T {
    guard let actual else {
        throw failure("\(what()): expected a value, got nil", file: file, line: line)
    }
    return actual
}

/// Asserts that `body` throws. An unrecognised `status` must not decode.
func expectThrows(
    _ body: () throws -> Void,
    _ what: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    do {
        try body()
    } catch {
        return
    }
    throw failure("\(what()): expected a decoding error, but it succeeded", file: file, line: line)
}
