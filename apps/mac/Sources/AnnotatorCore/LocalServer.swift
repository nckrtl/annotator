import Foundation

/// Controls only servers registered in Annotator's own state directory.
public struct LocalServer: Sendable {
    public let port: Int
    public let home: URL

    public init?(url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              url.path == "/annotations", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { return nil }
        port = url.port ?? 80
        self.home = home
    }

    public var state: URL { home.appending(path: ".annotator/server-\(port).json") }
    public var log: URL { home.appending(path: ".annotator/server-\(port).log") }
    public var store: URL {
        let existing = home.appending(path: ".t3/dev/annotations")
        return FileManager.default.fileExists(atPath: existing.path)
            ? existing : home.appending(path: ".annotator/annotations")
    }

    public struct Result: Decodable, Sendable {
        public let running: Bool
        public let error: String?
    }

    public func run(_ command: String) async throws -> Result {
        try await Task.detached {
            let files = FileManager.default
            let candidates = [".vite-plus/bin/node", ".local/share/mise/shims/node"].map {
                home.appending(path: $0).path
            } + ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            guard let node = candidates.first(where: { files.isExecutableFile(atPath: $0) }) else {
                throw Failure("Node.js was not found. Install Node.js 22 or newer to start the annotation server.")
            }
            let script = home.appending(path: "apps/annotator/bin/serve.mjs")
            guard files.fileExists(atPath: script.path) else {
                throw Failure("The annotation server was not found at \(script.path).")
            }
            let output = files.temporaryDirectory.appending(path: "annotator-command-\(UUID().uuidString)")
            files.createFile(atPath: output.path, contents: nil)
            defer { try? files.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [script.path, command, "--state", state.path]
            if command == "start" {
                process.arguments! += ["--port", String(port), "--store", store.path]
            }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            // Bound a hung runtime without blocking the app's main thread.
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate()
                throw Failure("The server command timed out. See \(log.path).")
            }
            let data = try Data(contentsOf: output)
            guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
                throw Failure(String(data: data, encoding: .utf8) ?? "The server returned an unreadable response.")
            }
            if let error = result.error { throw Failure(error) }
            guard process.terminationStatus == 0 else { throw Failure("The server command failed. See \(log.path).") }
            return result
        }.value
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
