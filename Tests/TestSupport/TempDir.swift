import Foundation

/// One unique directory under the user's temporary directory, owned by a
/// test.
///
/// The directory and everything below it are removed when the object is
/// deallocated, which for a `let temp = TempDir()` on a test struct happens at
/// the end of that test — including when the test fails or throws. A test that
/// keeps one in a harness class gets the same cleanup from the harness's
/// lifetime.
///
/// Removal makes every item writable first: fixtures such as a `0555`
/// destination or a `0400` snapshot are legitimate test data, and a read-only
/// mode bit must not turn a passing test into a temp-directory leak.
public final class TempDir: @unchecked Sendable {
    /// The directory itself.
    public let url: URL

    /// The directory path, for APIs that take a `String`.
    public var path: String { url.path }

    /// Creates `<temporaryDirectory>/<prefix>-<uuid>/`.
    ///
    /// A failure here means the machine cannot run the suite at all; the test
    /// must not pass silently, so this is a trap rather than a failable init.
    public init(prefix: String = "disktriage-tests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fatalError("cannot create a temporary test directory at \(url.path): \(error)")
        }
    }

    /// A path below this directory, not created.
    public func child(_ name: String) -> String {
        url.appendingPathComponent(name).path
    }

    /// A new subdirectory, created, with a unique name unless one is given.
    @discardableResult
    public func makeDirectory(_ name: String = "dir-\(UUID().uuidString)") throws -> String {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    /// Removes the directory and its contents. Idempotent; called by `deinit`.
    public func remove() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return }

        // A directory with mode `000` cannot be enumerated, so open the root
        // first, then walk and make every item writable.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)

        if let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) {
            for case let item as URL in enumerator {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                    ?? false
                try? manager.setAttributes(
                    [.posixPermissions: isDirectory ? 0o700 : 0o600],
                    ofItemAtPath: item.path
                )
            }
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try? manager.removeItem(at: url)
    }

    deinit {
        remove()
    }
}
