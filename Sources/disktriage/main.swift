import Foundation
import DiskTriageCLI

// Thin shell: all decisions live in DiskTriageCLI so they are testable through
// `run(arguments:readFile:now:)` without a process.
let result = run(arguments: Array(CommandLine.arguments.dropFirst()))

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.exitCode)
