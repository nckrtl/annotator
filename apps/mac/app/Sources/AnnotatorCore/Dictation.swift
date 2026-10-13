import Foundation
import Observation

/// A comment owns one recording. Cancelling invalidates every late response and paste wait.
@MainActor @Observable public final class Dictation {
    public private(set) var phase = "idle"
    public private(set) var error: String?
    @ObservationIgnored public var call: (String) async throws -> JSON = { _ in .null }
    @ObservationIgnored public var text: () -> String = { "" }
    @ObservationIgnored public var focus: () -> Void = {}
    @ObservationIgnored public var requestClose: () -> Void = {}
    @ObservationIgnored public var reportError: (String) -> Void = { _ in }
    @ObservationIgnored public var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var cancellation: Task<Void, Never>?
    private var generation = 0
    private var before = ""
    private var started: Double = 0
    public init() {}
    public func start() {
        guard phase == "idle" else { return }
        generation += 1; let session = generation
        phase = "starting"; error = nil; before = text(); started = Date().timeIntervalSince1970 * 1000
        let priorCancellation = cancellation
        startTask = Task {
            await priorCancellation?.value
            guard session == generation else { return }
            do {
                focus()
                let reply = try await call("start")
                guard session == generation else { return }
                try check(reply)
                phase = "recording"
                watchTask = Task { await watch(session) }
            } catch { if session == generation { self.error = error.localizedDescription; phase = "idle" } }
        }
    }
    public func cancel() {
        let active = phase != "idle"
        generation += 1; phase = "idle"; error = nil
        watchTask?.cancel()
        guard active else { return }
        let start = startTask
        cancellation = Task {
            await start?.value
            do {
                let reply = try await call("cancel")
                if reply["result"].string != "noDictation" { try check(reply) }
            } catch { reportError("Could not cancel Ofide: \(error.localizedDescription)") }
        }
    }
    /// Returns only after a paste has settled; a failed dictation never submits stale text.
    public func finish() async throws {
        let session = generation
        await startTask?.value
        guard session == generation else { throw CancellationError() }
        if phase == "recording" {
            phase = "transcribing"; watchTask?.cancel()
            do {
                focus(); try check(try await call("stop"))
                guard await waitForPaste(session) else { throw BridgeError("Ofide sent no text to the comment. Try again or type your comment.") }
                guard session == generation else { throw CancellationError() }
                phase = "idle"; error = nil
            } catch {
                if session == generation { self.error = error.localizedDescription; phase = "idle" }
                throw error
            }
        } else if phase == "transcribing" { await watchTask?.value }
        guard session == generation else { throw CancellationError() }
        if let error, text() == before { throw BridgeError(error) }
    }
    private func watch(_ session: Int) async {
        do {
            for _ in 0..<800 {
                try await sleep(.milliseconds(150))
                guard session == generation, !Task.isCancelled else { return }
                let reply = try await call("status")
                guard session == generation, !Task.isCancelled else { return }
                if reply["cancelledAt"].double >= started { phase = "idle"; generation += 1; requestClose(); return }
                try check(reply)
                let state = reply["status"].string
                if ["loading", "arming", "recording"].contains(state) { continue }
                phase = "transcribing"
                if state == "transcribing" { continue }
                guard !state.isEmpty else { throw BridgeError("Ofide stopped answering.") }
                guard await waitForPaste(session) else { throw BridgeError("Ofide finished without text. Try again or type your comment.") }
                guard session == generation else { return }
                phase = "idle"; error = nil; return
            }
            throw BridgeError("Ofide did not finish within two minutes.")
        } catch is CancellationError {} catch { if session == generation { self.error = error.localizedDescription; phase = "idle" } }
    }
    private func waitForPaste(_ session: Int) async -> Bool {
        for _ in 0..<60 {
            guard session == generation, !Task.isCancelled else { return false }
            if text() != before {
                let previous = text(); try? await sleep(.milliseconds(250))
                if text() == previous { return session == generation && !Task.isCancelled }
            }
            try? await sleep(.milliseconds(50))
        }
        return false
    }
    private func check(_ reply: JSON) throws {
        let result = reply["result"].string
        if result == "ok" { return }
        let message: String
        switch result {
        case "silence": message = "Ofide heard only silence."
        case "noDictation": message = "No active dictation, or focus changed."
        case "notRunning": message = "Ofide is not running."
        case "unauthorized": message = "Ofide rejected its Local API token. Check Ofide Settings."
        default: message = reply["message"].string.isEmpty ? "Ofide stopped answering." : reply["message"].string
        }
        throw BridgeError(message)
    }
}
