/// DiskDoctorCore — the portable half of DiskDoctor.
///
/// Everything in this module is a pure function over recorded signals: no I/O,
/// no OS calls, no subprocesses. Collectors and the CLI live outside it, so the
/// core can be replayed against fixtures on any platform (see diskdoctor.md §3).
public enum DiskDoctorCoreInfo {
    /// The SignalSet schema this build understands (diskdoctor.md §3).
    public static let supportedSchemaVersion = 1
}
