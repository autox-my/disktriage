// dadissent — DiskArbitration mount-DISSENT probe (P0 row 5, runbook A5/B3).
//
// DOES: create one DiskArbitration session, register a mount-approval callback
//       that returns a dissenter (kDAReturnExclusiveAccess) ONLY for disks whose
//       DA description says DeviceInternal == false AND DeviceProtocol == "USB"
//       (external physical USB); it approves everything else. It also registers
//       appeared / description-changed callbacks that only log. Every decision
//       is one line on stderr, flushed. Runs for --seconds N (default 120) and
//       exits 0.
//
// DOES NOT: mount, unmount, eject, claim, rename, or otherwise drive any device;
//       it opens, reads, and writes no disk, creates no files, and makes no
//       subprocess or network calls. Its only effect is a veto on the mount
//       path, and only while it runs.
//
// Verified against the SDK headers: DADiskMountApprovalCallback is a C function
// pointer (not a block) returning DADissenterRef (NULL approves); Swift 6 imports
// the return as Unmanaged<DADissenter>?. DADissenterCreate has no disk argument.

import Foundation
import DiskArbitration
import CoreFoundation

// MARK: - logging

private func timestamp() -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: Date())
}

private func log(_ message: String) {
    fputs("\(timestamp()) \(message)\n", stderr)
    fflush(stderr)
}

// MARK: - disk description accessors

private func describe(_ disk: DADisk) -> [String: Any] {
    guard let cf = DADiskCopyDescription(disk) else { return [:] }
    return cf as NSDictionary as? [String: Any] ?? [:]
}

private func stringField(_ desc: [String: Any], _ key: CFString) -> String? {
    desc[key as String] as? String
}

private func boolField(_ desc: [String: Any], _ key: CFString) -> Bool? {
    if let n = desc[key as String] as? NSNumber { return n.boolValue }
    return desc[key as String] as? Bool
}

private func bsdName(_ disk: DADisk) -> String {
    guard let name = DADiskGetBSDName(disk) else { return "?" }
    return String(cString: name)
}

/// Absent or unreadable fields are "unknown", and unknown approves: the probe
/// must never veto a mount it cannot positively identify as an external USB disk.
private func isExternalUSB(_ desc: [String: Any]) -> Bool {
    guard let isInternal = boolField(desc, kDADiskDescriptionDeviceInternalKey) else { return false }
    guard let proto = stringField(desc, kDADiskDescriptionDeviceProtocolKey) else { return false }
    return isInternal == false && proto == "USB"
}

private func summary(_ desc: [String: Any]) -> String {
    let proto = stringField(desc, kDADiskDescriptionDeviceProtocolKey) ?? "?"
    let internalFlag = boolField(desc, kDADiskDescriptionDeviceInternalKey).map { "\($0)" } ?? "?"
    let fs = stringField(desc, kDADiskDescriptionVolumeKindKey) ?? "?"
    return "protocol=\(proto) internal=\(internalFlag) fs=\(fs)"
}

// MARK: - callbacks (captureless; C function pointers)

private func mountApproval(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) -> Unmanaged<DADissenter>? {
    _ = context
    let desc = describe(disk)
    let usb = isExternalUSB(desc)
    log("decision bsd=\(bsdName(disk)) \(summary(desc)) verdict=\(usb ? "dissent" : "approve")")
    guard usb else { return nil }
    let dissenter = DADissenterCreate(
        kCFAllocatorDefault,
        DAReturn(kDAReturnExclusiveAccess),
        "dadissent: external USB disk held by the P0 probe" as CFString
    )
    return Unmanaged.passRetained(dissenter)
}

private func diskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    _ = context
    let desc = describe(disk)
    log("appeared bsd=\(bsdName(disk)) \(summary(desc))")
}

private func diskChanged(_ disk: DADisk, _ keys: CFArray, _ context: UnsafeMutableRawPointer?) {
    _ = context
    var changed: [String] = []
    for case let key as String in keys as NSArray { changed.append(key) }
    let desc = describe(disk)
    log("changed bsd=\(bsdName(disk)) keys=[\(changed.joined(separator: ","))] \(summary(desc))")
}

// MARK: - arguments

private func seconds(from arguments: [String]) -> Double? {
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--seconds" {
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else {
                return nil
            }
            return value
        }
        if arg.hasPrefix("--seconds=") {
            guard let value = Double(arg.dropFirst("--seconds=".count)), value > 0 else { return nil }
            return value
        }
        index += 1
    }
    return 120
}

// MARK: - entry point (top-level: this file is the main file)

guard let duration = seconds(from: CommandLine.arguments) else {
    fputs("usage: dadissent [--seconds N]   (N > 0, default 120)\n", stderr)
    exit(64)
}

setvbuf(stderr, nil, _IONBF, 0)

guard let session = DASessionCreate(kCFAllocatorDefault) else {
    fputs("dadissent: DASessionCreate failed\n", stderr)
    exit(1)
}

guard let runLoop = CFRunLoopGetCurrent() else {
    fputs("dadissent: no current run loop\n", stderr)
    exit(1)
}

let match = [
    kDADiskDescriptionDeviceInternalKey as String: false,
    kDADiskDescriptionDeviceProtocolKey as String: "USB",
] as NSDictionary

let watch = [
    kDADiskDescriptionVolumeKindKey as String,
    kDADiskDescriptionVolumePathKey as String,
    kDADiskDescriptionVolumeNameKey as String,
    kDADiskDescriptionDeviceProtocolKey as String,
    kDADiskDescriptionDeviceInternalKey as String,
] as NSArray

DARegisterDiskMountApprovalCallback(session, match as CFDictionary, mountApproval, nil)
DARegisterDiskAppearedCallback(session, nil, diskAppeared, nil)
DARegisterDiskDescriptionChangedCallback(session, nil, watch as CFArray, diskChanged, nil)

DASessionScheduleWithRunLoop(session, runLoop, CFRunLoopMode.defaultMode.rawValue)

log("start pid=\(getpid()) uid=\(getuid()) seconds=\(Int(duration)) approval=match(USB,external) status=kDAReturnExclusiveAccess")

let deadline = CFAbsoluteTimeGetCurrent() + duration
let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, deadline, 0, 0, 0) { _ in
    CFRunLoopStop(CFRunLoopGetCurrent())
}
CFRunLoopAddTimer(runLoop, timer, .defaultMode)

CFRunLoopRun()

CFRunLoopTimerInvalidate(timer)
DASessionUnscheduleFromRunLoop(session, runLoop, CFRunLoopMode.defaultMode.rawValue)
log("stop seconds=\(Int(duration))")
exit(0)
