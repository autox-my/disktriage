import Foundation
import DiskArbitration
import CoreFoundation
import Darwin

/// The live dissent runtime: one DiskArbitration session, a mount-approval
/// callback that asks the pure `guardDecision`, and appeared/changed callbacks
/// that only observe.
///
/// It never mounts, unmounts, ejects or claims a disk; its only effect is a
/// veto on the mount path while it runs. The callback is a C function pointer,
/// so the session state crosses into it as an unretained context pointer.
public struct DiskArbitrationDissent: DissentRunning {
    public init() {}

    public func run(
        seconds: Double?,
        onEvent: @escaping @Sendable (GuardEvent) -> Void
    ) -> GuardRunOutcome {
        installGuardSignalHandlers()

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return .failed("DASessionCreate failed")
        }
        guard let runLoop = CFRunLoopGetCurrent() else {
            return .failed("no current run loop")
        }

        let box = GuardSessionBox(onEvent: onEvent)
        let context = Unmanaged.passUnretained(box).toOpaque()

        let watch = [
            kDADiskDescriptionVolumeKindKey as String,
            kDADiskDescriptionVolumePathKey as String,
            kDADiskDescriptionVolumeNameKey as String,
            kDADiskDescriptionDeviceProtocolKey as String,
            kDADiskDescriptionDeviceInternalKey as String,
        ] as NSArray

        // No match dictionary: every approval is decided by the pure function,
        // so an approve is logged as explicitly as a dissent.
        DARegisterDiskMountApprovalCallback(session, nil, guardMountApprovalCallback, context)
        DARegisterDiskAppearedCallback(session, nil, guardDiskAppearedCallback, context)
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            watch as CFArray,
            guardDiskChangedCallback,
            context
        )
        DASessionScheduleWithRunLoop(session, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let deadline = seconds.map { CFAbsoluteTimeGetCurrent() + $0 }
        while !guardInterrupted {
            if let deadline, CFAbsoluteTimeGetCurrent() >= deadline { break }
            let slice: CFTimeInterval
            if let deadline {
                slice = min(0.25, max(0.01, deadline - CFAbsoluteTimeGetCurrent()))
            } else {
                slice = 0.25
            }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, slice, true)
        }

        DASessionUnscheduleFromRunLoop(session, runLoop, CFRunLoopMode.defaultMode.rawValue)
        return guardInterrupted ? .interrupted : .elapsed
    }
}

/// The state the C callbacks can reach. It is only touched on the run-loop
/// thread; `@unchecked Sendable` covers the C context pointer.
private final class GuardSessionBox: @unchecked Sendable {
    private let onEvent: @Sendable (GuardEvent) -> Void

    init(onEvent: @escaping @Sendable (GuardEvent) -> Void) {
        self.onEvent = onEvent
    }

    func mountApproval(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        let description = DiskDescription(daDescription: descriptionDictionary(disk))
        let verdict = guardDecision(description)
        onEvent(
            .decision(
                GuardDecisionRecord(
                    bsd: bsdName(disk),
                    description: description,
                    verdict: verdict
                )
            )
        )
        guard verdict == .dissent else { return nil }
        let dissenter = DADissenterCreate(
            kCFAllocatorDefault,
            DAReturn(kDAReturnExclusiveAccess),
            "disktriage guard: external disk held; the mount is refused (probe reads may still happen)" as CFString
        )
        return Unmanaged.passRetained(dissenter)
    }

    func appeared(_ disk: DADisk) {
        onEvent(
            .appeared(
                bsd: bsdName(disk),
                description: DiskDescription(daDescription: descriptionDictionary(disk))
            )
        )
    }

    func changed(_ disk: DADisk, keys: [String]) {
        onEvent(
            .changed(
                bsd: bsdName(disk),
                keys: keys,
                description: DiskDescription(daDescription: descriptionDictionary(disk))
            )
        )
    }
}

// MARK: - C callbacks

private func guardMountApprovalCallback(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<DADissenter>? {
    guard let context else { return nil }
    return Unmanaged<GuardSessionBox>.fromOpaque(context)
        .takeUnretainedValue()
        .mountApproval(disk)
}

private func guardDiskAppearedCallback(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<GuardSessionBox>.fromOpaque(context).takeUnretainedValue().appeared(disk)
}

private func guardDiskChangedCallback(
    _ disk: DADisk,
    _ keys: CFArray,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    var changed: [String] = []
    for case let key as String in keys as NSArray { changed.append(key) }
    Unmanaged<GuardSessionBox>.fromOpaque(context).takeUnretainedValue().changed(disk, keys: changed)
}

// MARK: - Description accessors

private func descriptionDictionary(_ disk: DADisk) -> [String: Any] {
    guard let cf = DADiskCopyDescription(disk) else { return [:] }
    return cf as NSDictionary as? [String: Any] ?? [:]
}

private func bsdName(_ disk: DADisk) -> String {
    guard let name = DADiskGetBSDName(disk) else { return "?" }
    return String(cString: name)
}
