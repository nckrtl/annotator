import Foundation

/// Only step/reason codes and numeric focus diagnostics belong here. Never log tokens, response bodies, or comment text.
public enum DictationLog {
    private static let queue = DispatchQueue(label: "com.nckrtl.annotator.dictation-log")
    public static func write(_ step: String) {
        queue.async {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.nckrtl.annotator")
            let file = directory.appendingPathComponent("dictation.log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 512_000 {
                    let previous = directory.appendingPathComponent("dictation.previous.log")
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: file, to: previous)
                }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\(Date().ISO8601Format()) \(step)\n".utf8))
            } catch { /* Logging must never hold the screen. */ }
        }
    }
}
