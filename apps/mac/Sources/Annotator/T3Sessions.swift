import AnnotatorCore
import AppKit
import Darwin
import Security

/// Starts agent sessions in a local Conn and keeps them fed: one thread per project, opened in the
/// Conn window, with a short follow-up when new annotations arrive and the thread is idle.
@MainActor
final class T3Sessions {
    struct Session: Codable {
        var threadId: String
        /// Annotations made before this are covered by the first prompt.
        var started: Date
        /// The server's data folder. Sessions on another server are ignored after a settings change.
        var server: String?
    }

    private let settings: Settings
    /// Per project id. Kept across launches, so nudges keep going to the same thread.
    private(set) var sessions: [String: Session]
    /// Annotation ids already sent as nudges in this run, so each one is sent once.
    private var announced = Set<String>()
    private var nudging = false
    private var timer: Timer?
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    /// The latest queue and projects, so the timer can retry a nudge for a thread that was busy.
    private var latest: (summary: QueueSummary, projects: [Project])?

    init(settings: Settings) {
        self.settings = settings
        sessions = (UserDefaults.standard.data(forKey: "t3Sessions"))
            .flatMap { try? JSONDecoder().decode([String: Session].self, from: $0) } ?? [:]
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryNudge() }
        }
    }

    /// The server that runs the sessions.
    var instance: T3Instance {
        T3Instance(home: URL(fileURLWithPath: (settings.t3Home as NSString).expandingTildeInPath))
    }

    /// The desktop window that shows them.
    var window: T3Instance {
        T3Instance(home: URL(fileURLWithPath: (settings.t3WindowHome as NSString).expandingTildeInPath))
    }

    private func session(_ project: Project) -> Session? {
        guard let session = sessions[project.id], (session.server == settings.t3Endpoint || (session.server == instance.home.path && settings.t3Endpoint == "http://127.0.0.1:3780")) else { return nil }
        return session
    }

    func hasSession(_ project: Project) -> Bool { session(project) != nil }

    // MARK: - Starting

    /// Creates a thread in the project's folder, sends the prompt, and opens it in the Conn window.
    func start(_ project: Project, prompt: String) async {
        do {
            guard !project.root.isEmpty else { throw T3Error.unexpected("Set a folder for \(project.name) in Settings › Projects first.") }
            let client = try await authorizedClient()
            let threadId = try await withReauthorization(client) { client in
                let snapshot = try await client.snapshot()
                let projectId: String
                if let existing = snapshot.project(root: project.root) {
                    projectId = existing.id
                } else {
                    projectId = T3Command.uuid()
                    try await client.dispatch(T3Command.createProject(id: projectId, title: project.name, root: project.root))
                }
                // The project's model, then the default from Settings, then the server's most recent thread.
                guard let model = T3ModelSelection(project.t3Model) ?? T3ModelSelection(settings.t3DefaultModel)
                    ?? snapshot.latestModel
                else {
                    throw T3Error.unexpected(
                        "Set a default model in Settings › General › Conn, such as codex/gpt-6.1-sol. This server has no threads to copy one from.")
                }
                let threadId = T3Command.uuid()
                try await client.dispatch(T3Command.createThread(
                    id: threadId, projectId: projectId, title: "Annotations · \(project.name)",
                    model: model, runtimeMode: project.t3RuntimeMode, effort: settings.t3Effort))
                try await client.dispatch(T3Command.sendMessage(
                    threadId: threadId, text: prompt, runtimeMode: project.t3RuntimeMode,
                    titleSeed: "Annotations · \(project.name)"))
                return threadId
            }
            sessions[project.id] = Session(threadId: threadId, started: Date(), server: settings.t3Endpoint)
            save()
            lastError = nil
            onChange?()
            log.info("Conn session \(threadId, privacy: .public) started for \(project.name, privacy: .public)")
            // Showing the desktop window is an explicit, separate action.

        } catch {
            report("Could not start a Conn session for \(project.name): \(error)")
        }
    }

    /// Focuses the Conn window and shows the project's session.
    func open(_ project: Project) async {
        guard let session = session(project) else { return }
        do { try await open(threadId: session.threadId) } catch {
            report("Could not open the Conn session for \(project.name): \(error)")
        }
    }

    private func open(threadId: String) async throws {
        guard try instance.runtime().origin == settings.t3Endpoint else {
            throw T3Error.unexpected("Open this session in a Conn window connected to \(settings.t3Endpoint). The configured local window belongs to a different server.")
        }
        // The thread lives on the server's environment; the window shows it once it is paired with that server.
        let socket = window.controlSocket(
            temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), uid: getuid())
        let request = T3Command.openThread(environmentId: try instance.environmentId(), threadId: threadId)
        // Right after creation the window may not know the thread yet: retry for about three seconds.
        for attempt in 0..<8 {
            let reply = try await T3Sessions.send(request, to: socket)
            if reply["ok"] as? Bool == true { return }
            let code = (reply["code"] as? String) ?? (reply["error"] as? String) ?? "unknown"
            if code == "thread-not-found", attempt == 7, window.home != instance.home {
                throw T3Error.rejected(
                    "the Conn window does not know this server yet. Pair it once: menu › Conn Sessions › Copy Pairing URL, then paste the URL in Conn under Settings › Connections › Add environment.")
            }
            if code != "thread-not-found" || attempt == 7 {
                throw T3Error.rejected("the Conn window did not open the thread (\(code)).")
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    // MARK: - Nudges

    /// Sends new annotations to their project's idle session. Called on every queue change.
    func nudge(summary: QueueSummary, projects: [Project]) {
        latest = (summary, projects)
        guard settings.t3Enabled, settings.t3Nudge, !nudging, !sessions.isEmpty else { return }
        let work: [(Project, Session, [QueueItem])] = projects.compactMap { project in
            // A full-access thread runs tools without asking. Do not feed it new work on its own.
            guard project.t3RuntimeMode != "full-access", let session = session(project) else { return nil }
            let since = Int64(session.started.timeIntervalSince1970 * 1000)
            let fresh = summary.open.filter {
                $0.status == "todo" && $0.question != true && $0.native?.project == project.name
                    && ($0.createdAt ?? 0) > since && !announced.contains($0.id)
            }
            return fresh.isEmpty ? nil : (project, session, fresh)
        }
        guard !work.isEmpty else { return }
        nudging = true
        Task {
            defer { nudging = false }
            do {
                let client = try await authorizedClient()
                for (project, session, items) in work {
                    try await withReauthorization(client) { client in
                        let thread: T3Snapshot.Thread
                        do { thread = try await client.thread(id: session.threadId) } catch T3Error.rejected(let message)
                            where message.hasPrefix("404") {
                            // The thread was deleted in T3: stop sending to it.
                            sessions[project.id] = nil
                            save()
                            return
                        }
                        guard thread.isIdle else { return }  // The timer tries again.
                        let numbers = items.compactMap(\.number)
                        try await client.dispatch(T3Command.sendMessage(
                            threadId: session.threadId, text: T3Nudge.text(numbers: numbers),
                            runtimeMode: project.t3RuntimeMode))
                        announced.formUnion(items.map(\.id))
                        log.info("Nudged Conn session for \(project.name, privacy: .public): \(numbers)")
                    }
                }
                lastError = nil
            } catch {
                report("Could not send new annotations to T3: \(error)")
            }
            onChange?()
        }
    }

    private func retryNudge() {
        guard let latest else { return }
        nudge(summary: latest.summary, projects: latest.projects)
    }

    // MARK: - Access

    private func authorizedClient() async throws -> T3Client {
        guard let origin = Settings.validURL(settings.t3Endpoint) else {
            throw T3Error.unexpected("Enter your Conn server endpoint in Settings.")
        }
        if let token = try Keychain.read(account: settings.t3Endpoint) {
            return T3Client(origin: origin, token: token)
        }
        // Preserve the existing local connection without minting any new credentials.
        if settings.t3Endpoint == "http://127.0.0.1:3780",
           let token = try Keychain.read(account: instance.home.path) {
            try Keychain.save(token, account: settings.t3Endpoint)
            return T3Client(origin: origin, token: token)
        }
        throw T3Error.unexpected("Add a Conn access token in Settings. Create it on your Conn server with auth session issue.")
    }

    private func withReauthorization<T>(_ client: T3Client, _ body: (T3Client) async throws -> T) async throws -> T {
        do { return try await body(client) } catch T3Error.unauthorized {
            throw T3Error.unexpected("Conn rejected the access token. Create a new token on your server and save it in Settings.")
        }
    }

    /// Runs Conn's CLI with the same executable and script as the running server, so versions always match.
    private func runCLI(_ runtime: T3Instance.Runtime, _ arguments: [String]) async throws -> String {
        let processArguments = T3Sessions.processArguments(pid: runtime.pid)
        guard let executable = processArguments.first,
            let script = processArguments.first(where: { $0.hasSuffix("bin.mjs") })
        else {
            throw T3Error.notRunning(
                "Could not find Conn's command-line tool from its running server (pid \(runtime.pid)). Is the Conn server running?")
        }
        guard AppBundleTrust.installed(executable: executable, script: script) else {
            throw T3Error.unexpected("The Conn command-line tool must be inside an app in /Applications.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [script] + arguments
            // The server's environment can hold tokens. Pass only what the CLI needs.
            process.environment = [
                "ELECTRON_RUN_AS_NODE": "1",
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": home,
            ]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw T3Error.rejected("Conn's CLI failed: \(String(decoding: errors.prefix(300), as: UTF8.self))")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// A fresh 15-minute pairing URL for the server, to add it in a Conn window under Settings › Connections.
    func pairingURL() async -> String? {
        do {
            let runtime = try instance.runtime()
            guard runtime.origin == settings.t3Endpoint else {
                throw T3Error.unexpected("Create a pairing link on your selected Conn server with t3 pair.")
            }
            let output = try await runCLI(runtime, ["pair", "--base-dir", instance.home.path, "--label", "Annotator sessions", "--ttl", "15m"])
            guard let line = output.split(separator: "\n").first(where: { $0.contains("/pair#token=") }),
                let url = line.split(separator: " ").last(where: { $0.contains("/pair#token=") })
            else { throw T3Error.unexpected("Conn's CLI printed no pairing URL.") }
            return String(url)
        } catch {
            report("Could not create a pairing URL: \(error)")
            return nil
        }
    }

    func forgetToken() {
        Keychain.delete(account: instance.home.path)
    }

    var hasToken: Bool { (try? Keychain.read(account: instance.home.path)) != nil }

    private func report(_ message: String) {
        lastError = message
        log.error("\(message, privacy: .public)")
        onChange?()
        let alert = NSAlert()
        alert.messageText = "Conn"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(sessions), forKey: "t3Sessions")
    }

    // MARK: - System helpers

    /// A process's arguments, read with `KERN_PROCARGS2`: argc, the executable path, then argv.
    nonisolated static func processArguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }  // The executable path.
        while index < size, buffer[index] == 0 { index += 1 }  // Padding.
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// One JSON line to a Unix socket, one JSON line back. Blocking I/O runs off the main actor.
    nonisolated static func send(_ request: [String: Any], to socket: URL) async throws -> [String: Any] {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { throw T3Error.unexpected("Bad request") }
        let path = socket.path
        let reply = try await Task.detached { () throws -> Data in
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw T3Error.unexpected("Could not create a socket.") }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw T3Error.unexpected("Socket path too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                throw T3Error.notRunning("The Conn window is not open (no control socket at \(path)). Start it and try again.")
            }
            var line = body
            line.append(0x0A)
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var reply = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !reply.contains(0x0A) {
                let count = read(fd, &chunk, chunk.count)
                if count <= 0 { break }
                reply.append(contentsOf: chunk[0..<count])
            }
            return reply
        }.value
        guard let object = try? JSONSerialization.jsonObject(with: reply.prefix { $0 != 0x0A }) as? [String: Any] else {
            throw T3Error.unexpected("The Conn window gave no answer.")
        }
        return object
    }
}

/// The Conn token in the login Keychain, one item per Conn data folder.
enum Keychain {
    static let service = "com.nckrtl.annotator.t3"

    static func read(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw T3Error.unexpected("Could not read the Conn token from the Keychain (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, account: String) throws {
        delete(account: account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                   kSecAttrLabel as String: "Annotator: Conn token"]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw T3Error.unexpected("Could not save the Conn token in the Keychain (\(status)).") }
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
