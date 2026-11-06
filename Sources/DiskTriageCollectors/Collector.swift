/// The collector seam.
///
/// P1c implements only `DeviceCollector`, the one signal family that can be
/// verified without external hardware. The SMART, ioreg I/O-statistics and
/// unified-log parsers are deliberately absent until the bench records real
/// USB-HDD output (bench Phase B); the TODO list is in
/// `docs/collectors-observations.md`. Until then their sections are
/// `unsupported` with a reason, never absent and never zero.
public protocol Collector: Sendable {
    /// The collector's stable name, as used in `collector_notes`.
    var name: String { get }
}
