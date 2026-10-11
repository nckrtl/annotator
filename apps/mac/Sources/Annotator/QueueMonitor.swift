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

    @ObservationIgnored
    private let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The server sends a heartbeat every 15 s.
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = .infinity
        return URLSession(configuration: configuration)
    }()

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
            // The stream dropped or never opened. Poll until the server answers, then try the stream again.
            repeat {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
            } while await !refresh(client)
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

    @discardableResult
    private func refresh(_ client: AnnotationClient) async -> Bool {
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
