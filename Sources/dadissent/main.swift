// dadissent — DiskArbitration mount-DISSENT probe (P0 row 5, runbook A5/B3).
//
// This is now a thin entry point: the session, the callback and the decision
// live in DiskTriageGuard, shared with `disktriage guard`. It dissents only for
// an external physical disk (DeviceInternal == false and a physical protocol)
// and approves everything else.
//
// DOES NOT mount, unmount, eject, claim or write anything, and makes no
// subprocess or network calls. Its only effect is a veto on the mount path,
// and only while it runs.

import Foundation
import DiskTriageGuard

#if canImport(Darwin)
import Darwin
#endif

private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func log(_ message: String) {
    fputs("\(timestamp()) \(message)\n", stderr)
    fflush(stderr)
}

private func seconds(from arguments: [String]) -> Double? {
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--seconds" {
            guard index + 1 < arguments.count,
                  let value = Double(arguments[index + 1]),
                  value > 0, value.isFinite else {
                return nil
            }
            return value
        }
        if argument.hasPrefix("--seconds=") {
            guard let value = Double(argument.dropFirst("--seconds=".count)),
                  value > 0, value.isFinite else {
                return nil
            }
            return value
        }
        index += 1
    }
    return 120
}

guard let duration = seconds(from: CommandLine.arguments) else {
    fputs("usage: dadissent [--seconds N]   (N > 0, default 120)\n", stderr)
    exit(64)
}

setvbuf(stderr, nil, _IONBF, 0)

log(
    "start pid=\(getpid()) uid=\(getuid()) seconds=\(Int(duration)) "
        + "approval=internal==false && physical protocol status=kDAReturnExclusiveAccess"
)

let outcome = DiskArbitrationDissent().run(seconds: duration) { event in
    switch event {
    case .decision(let record):
        log(ttyDecision(record))
    case .appeared(let bsd, let description):
        log("appeared bsd=\(bsd) \(descriptionSummary(description))")
    case .changed(let bsd, let keys, let description):
        log("changed bsd=\(bsd) keys=[\(keys.joined(separator: ","))] \(descriptionSummary(description))")
    }
}

if case .failed(let reason) = outcome {
    fputs("dadissent: \(reason)\n", stderr)
    exit(1)
}

log("stop seconds=\(Int(duration))")
exit(0)
