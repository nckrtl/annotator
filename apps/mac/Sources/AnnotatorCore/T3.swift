import CryptoKit
import Foundation

/// A local Conn install, found from its data folder (`T3CODE_HOME`): `~/.t3` for the app,
/// `~/.t3/desktop-dev` for the desktop dev build. Its HTTP API is internal (orchestration protocol 1),
/// so every request reports a clear error when the shape no longer matches.
public struct T3Instance: Sendable, Equatable {
    /// `T3CODE_HOME`. Runtime state lives in its `userdata` folder.
    public var home: URL

    public init(home: URL) {
        self.home = home
    }

    public var stateDirectory: URL { home.appending(path: "userdata", directoryHint: .isDirectory) }

    public struct Runtime: Decodable, Sendable, Equatable {
        public var pid: Int32
        public var origin: String
    }

    public func runtime() throws(T3Error) -> Runtime {
        let file = stateDirectory.appending(path: "server-runtime.json")
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw .notRunning("No \(file.path). Start Conn first.")
        }
        guard let runtime = try? JSONDecoder().decode(Runtime.self, from: data) else {
            throw .unexpected("Could not read \(file.path).")
        }
        return runtime
    }

    public func environmentId() throws(T3Error) -> String {
        let file = stateDirectory.appending(path: "environment-id")
        guard let data = FileManager.default.contents(atPath: file.path),
            let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else { throw .unexpected("Could not read \(file.path).") }
        return id
    }

    /// The desktop app's control socket: `$TMPDIR/t3code-<uid>/<first 24 hex of sha256(stateDir)>.sock`.
    public func controlSocket(temporaryDirectory: URL, uid: UInt32) -> URL {
        let digest = SHA256.hash(data: Data(stateDirectory.path(percentEncoded: false).trimmingSlash.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return temporaryDirectory.appending(path: "t3code-\(uid)/\(name).sock")
    }
}

extension String {
    var trimmingSlash: String { hasSuffix("/") && count > 1 ? String(dropLast()) : self }
}

/// Whether a Conn CLI binary and its script live in the same app under `/Applications`.
public enum AppBundleTrust {
    public static func installed(executable: String, script: String) -> Bool {
        let executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let script = URL(fileURLWithPath: script).resolvingSymlinksInPath().path
        guard script.hasSuffix("bin.mjs"), let app = application(containing: executable) else { return false }
        return app.hasPrefix("/Applications/") && script.hasPrefix(app + "/")
    }

    public static func application(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

public enum T3Error: Error, Equatable, CustomStringConvertible {
    case notRunning(String)
    case unauthorized
    case rejected(String)
    case unexpected(String)

    public var description: String {
        switch self {
        case .notRunning(let message): message
        case .unauthorized: "Conn rejected the access token."
        case .rejected(let message): "Conn refused the request: \(message)"
        case .unexpected(let message): message
        }
    }
}

public struct T3ModelSelection: Codable, Sendable, Equatable {
    public var instanceId: String
    public var model: String

    public init(instanceId: String, model: String) {
        self.instanceId = instanceId
        self.model = model
    }

    /// `codex/gpt-6.1-sol` → instance `codex`, model `gpt-6.1-sol`.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(instanceId: parts[0], model: parts[1])
    }

    public var text: String { "\(instanceId)/\(model)" }
}

/// The parts of Conn's read model this app uses.
public struct T3Snapshot: Decodable, Sendable {
    public struct Project: Decodable, Sendable {
        public var id: String
        public var title: String?
        public var workspaceRoot: String
        public var deletedAt: String?
    }

    public struct Thread: Decodable, Sendable {
        public var id: String
        public var projectId: String?
        public var modelSelection: T3ModelSelection?
        public var updatedAt: String?
        public var deletedAt: String?
        public var session: Session?

        public struct Session: Decodable, Sendable {
            public var status: String?
            public var activeTurnId: String?
        }

        /// No turn is running, so a new message starts work at once.
        public var isIdle: Bool { session?.activeTurnId == nil }
    }

    public var projects: [Project]
    public var threads: [Thread]

    /// The active project whose folder is `root`, comparing resolved paths.
    public func project(root: String) -> Project? {
        let wanted = T3Snapshot.normalize(root)
        return projects.first { $0.deletedAt == nil && T3Snapshot.normalize($0.workspaceRoot) == wanted }
    }

    /// The model of the most recently updated thread: a default that needs no setup.
    public var latestModel: T3ModelSelection? {
        threads.filter { $0.deletedAt == nil && $0.modelSelection != nil }
            .max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }?.modelSelection
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path.trimmingSlash
    }
}

/// Orchestration commands for `POST /api/orchestration/dispatch`.
public enum T3Command {
    public static func createProject(id: String, title: String, root: String, now: Date = Date()) -> [String: Any] {
        ["type": "project.create", "commandId": uuid(), "projectId": id, "title": title,
         "workspaceRoot": root, "createWorkspaceRootIfMissing": false, "createdAt": iso(now)]
    }

    public static func createThread(
        id: String, projectId: String, title: String, model: T3ModelSelection, runtimeMode: String, effort: String? = nil, now: Date = Date()
    ) -> [String: Any] {
        var selection: [String: Any] = ["instanceId": model.instanceId, "model": model.model]
        if let effort, !effort.isEmpty {
            selection["options"] = [["id": model.instanceId == "codex" ? "reasoningEffort" : "effort", "value": effort]]
        }
        return ["type": "thread.create", "commandId": uuid(), "threadId": id, "projectId": projectId, "title": title,
         "modelSelection": selection,
         "runtimeMode": runtimeMode, "interactionMode": "default",
         "branch": NSNull(), "worktreePath": NSNull(), "createdAt": iso(now)]
    }

    /// A user message. On a new thread it starts the agent; on an idle one it starts the next turn.
    public static func sendMessage(threadId: String, text: String, runtimeMode: String, titleSeed: String? = nil,
                                   now: Date = Date()) -> [String: Any] {
        var command: [String: Any] = [
            "type": "thread.turn.start", "commandId": uuid(), "threadId": threadId,
            "message": ["messageId": uuid(), "role": "user", "text": text, "attachments": [Any]()],
            "runtimeMode": runtimeMode, "interactionMode": "default", "createdAt": iso(now),
        ]
        if let titleSeed { command["titleSeed"] = titleSeed }
        return command
    }

    /// The desktop control socket request that focuses the window and shows the thread.
    public static func openThread(environmentId: String, threadId: String) -> [String: Any] {
        ["version": 1, "requestId": uuid(), "type": "open-thread", "environmentId": environmentId, "threadId": threadId]
    }

    public static func uuid() -> String { UUID().uuidString.lowercased() }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// The follow-up sent to an idle session when its project gets new annotations.
public enum T3Nudge {
    public static func text(numbers: [Int]) -> String {
        let list = numbers.sorted().map { "#\($0)" }.joined(separator: ", ")
        return "New annotations for this project: \(list). Work through them the same way as before, then end your turn."
    }
}

/// Conn's HTTP API at `origin`, with a bearer token.
public struct T3Client: Sendable {
    public var origin: URL
    public var token: String
    var transport: HTTPTransport

    public init(origin: URL, token: String, transport: @escaping HTTPTransport = HTTP.session(timeout: 15)) {
        self.origin = origin
        self.token = token
        self.transport = transport
    }

    public func snapshot() async throws(T3Error) -> T3Snapshot {
        let data = try await send(URLRequest(url: origin.appending(path: "api/orchestration/snapshot")))
        do { return try JSONDecoder().decode(T3Snapshot.self, from: data) } catch {
            throw .unexpected("Conn's snapshot has an unexpected shape. This Conn version may not be supported.")
        }
    }

    public func thread(id: String) async throws(T3Error) -> T3Snapshot.Thread {
        struct Body: Decodable { var thread: T3Snapshot.Thread }
        let data = try await send(URLRequest(url: origin.appending(path: "api/orchestration/threads/\(id)")))
        do { return try JSONDecoder().decode(Body.self, from: data).thread } catch {
            throw .unexpected("Conn's thread has an unexpected shape. This Conn version may not be supported.")
        }
    }

    public func dispatch(_ command: [String: Any]) async throws(T3Error) {
        var request = URLRequest(url: origin.appending(path: "api/orchestration/dispatch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: command) else {
            throw .unexpected("Could not encode the Conn command.")
        }
        request.httpBody = body
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws(T3Error) -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) } catch {
            throw .notRunning("Conn does not answer at \(origin.absoluteString): \(error.localizedDescription)")
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw .unauthorized
        default:
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw .rejected("\(response.statusCode) \(text)")
        }
    }
}
