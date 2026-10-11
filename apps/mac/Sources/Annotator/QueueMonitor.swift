import AnnotatorCore
import Foundation
import Observation

/// Keeps the queue counts live. Listens to the server's event stream; when the stream
/// drops, polls every 3 s and reports the server unreachable after three failed polls.
@MainActor @Observable
final class QueueMonitor {
    enum Connection: Equatable {
        case connecting
        case live
        case polling
        case unreachable(String)
        case wrongServer
        case invalidURL
    }

    private(set) var summary: QueueSummary?
    private(set) var connection = Connection.connecting
    @ObservationIgnored
    private var failedPolls = 0
    @ObservationIgnored
    private var task: Task<Void, Never>?
    /// Called after every change of `summary` or `connection`.
    @ObservationIgnored
    var onChange: (() -> Void)?
    /// Called when a refresh succeeds after one or more failures.
    @ObservationIgnored
    var onReachable: (() -> Void)?

    /// The server sends a heartbeat every 15 s. The session refuses a redirect to another host.
    @ObservationIgnored
    private let streamSession = HTTP.eventStream()
    @ObservationIgnored
    private var refreshing = false
    @ObservationIgnored
    private var needsRefresh = false

    func start(client: AnnotationClient?) {
        task?.cancel()
        summary = nil
        failedPolls = 0
        guard let client else {
            connection = .invalidURL
            onChange?()
            return
        }
        connection = .connecting
        onChange?()
        task = Task { await run(client) }
    }

    func refreshNow(_ client: AnnotationClient?) {
        guard let client else { return }
        Task { await refresh(client) }
    }

    private func run(_ client: AnnotationClient) async {
        while !Task.isCancelled {
            await listen(client)
            // A server that is not the annotation server will not become one by being asked again.
            if connection == .wrongServer || Task.isCancelled { return }
            // The stream dropped or never opened. Poll until the server answers, then try the stream again.
            var recovered = false
            while !recovered && !Task.isCancelled && connection != .wrongServer {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled || connection == .wrongServer { return }
                recovered = await refresh(client)
                if connection == .wrongServer { return }
            }
        }
    }

    private func listen(_ client: AnnotationClient) async {
        do {
            let (bytes, response) = try await streamSession.bytes(from: client.eventsURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            guard await refresh(client) else { return }
            setConnection(.live)
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                if line.hasPrefix("data:") { await refresh(client) }
            }
        } catch {
            // Fall through to polling.
        }
        if connection == .live { setConnection(.polling) }
    }

    /// One download at a time. A second caller waits for one more pass instead of starting its own.
    @discardableResult
    private func refresh(_ client: AnnotationClient) async -> Bool {
        if refreshing {
            needsRefresh = true
            return true
        }
        refreshing = true
        defer { refreshing = false }
        var ok = true
        repeat {
            needsRefresh = false
            ok = await load(client)
        } while needsRefresh && !Task.isCancelled
        return ok
    }

    private func load(_ client: AnnotationClient) async -> Bool {
        do {
            let summary = try await client.queue()
            let recovered = failedPolls > 0 || connection != .live
            failedPolls = 0
            self.summary = summary
            if connection != .live { connection = .polling }
            onChange?()
            if recovered { onReachable?() }
            return true
        } catch .notAnnotationServer {
            setConnection(.wrongServer)
            return false
        } catch {
            failedPolls += 1
            if failedPolls >= 3 { setConnection(.unreachable(error.description)) }
            return false
        }
    }

    private func setConnection(_ connection: Connection) {
        self.connection = connection
        onChange?()
    }
}
