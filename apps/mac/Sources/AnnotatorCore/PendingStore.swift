import Foundation

/// Local copies of annotations until the server stores them.
///
/// `pending/` holds records that wait for a retry. `failed/` holds records the
/// server refused, so the comment is never lost silently.
public struct PendingStore: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: PendingStore {
        PendingStore(root: URL.applicationSupportDirectory.appending(path: "Annotator", directoryHint: .isDirectory))
    }

    var pendingDirectory: URL { root.appending(path: "pending", directoryHint: .isDirectory) }
    public var failedDirectory: URL { root.appending(path: "failed", directoryHint: .isDirectory) }

    public func save(id: String, body: Data) throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try body.write(to: pendingDirectory.appending(path: "\(id).json"), options: .atomic)
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: pendingDirectory.appending(path: "\(id).json"))
    }

    /// Moves a refused record out of the retry queue.
    public func markFailed(id: String) throws {
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        let target = failedDirectory.appending(path: "\(id).json")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: pendingDirectory.appending(path: "\(id).json"), to: target)
    }

    /// Pending records, oldest first.
    public func pending() -> [(id: String, body: Data)] {
        records(in: pendingDirectory)
    }

    public func failedCount() -> Int {
        records(in: failedDirectory).count
    }

    func records(in directory: URL) -> [(id: String, body: Data)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
            .compactMap { url in
                (try? Data(contentsOf: url)).map { (url.deletingPathExtension().lastPathComponent, $0) }
            }
    }
}
