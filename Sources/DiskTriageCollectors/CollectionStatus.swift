import DiskTriageCore

/// Maps a subprocess outcome to the section status. A timeout, denial or
/// missing tool is evidence about the collection, never a measurement
/// (diskdoctor.md §2.3, REQ-0012).
extension CollectOutcome {
    var signalStatus: SignalStatus {
        switch self {
        case .ok: return .ok
        case .timeout: return .timeout
        case .denied: return .denied
        case .notFound, .error, .policyRejected: return .error
        }
    }
}
