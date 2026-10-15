import Foundation
import Observation

/// A comment owns one recording. Every exit releases the overlay before any network cleanup.
@MainActor @Observable public final class Dictation {
    public private(set) var phase = "idle"
    public private(set) var error: String?
    @ObservationIgnored public var call: (String) async throws -> JSON = { _ in .null }
    @ObservationIgnored public var text: () -> String = { "" }
    @ObservationIgnored public var focus: () async throws -> Void = {}
    @ObservationIgnored public var releaseOverlay: (String) -> Void = { _ in }
    @ObservationIgnored public var reportError: (String) -> Void = { _ in }
    @ObservationIgnored public var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    // Injectable deadlines keep failure tests fast. Production limits are independent of polling.
    @ObservationIgnored public var replyTimeout: Duration = .seconds(5)
    @ObservationIgnored public var stopTimeout: Duration = .seconds(18)
    @ObservationIgnored public var progressTimeout: Duration = .seconds(20)
    @ObservationIgnored public var recordingLimit: Duration = .seconds(120)
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var cancellation: Task<Void, Never>?
    private var generation = 0
    private var before = ""
    private var started: Double = 0
    public init() {}

    private func release(_ reason: String) {
        DictationLog.write("overlay-release \(reason)")
        releaseOverlay(reason)
    }
    private func request(_ action: String) async throws -> JSON {
        // Action comes only from this class, never from a server response.
        if action != "status" { DictationLog.write("dictation-\(action)") }
        let call = self.call
        let reply = try await Deadline().run(after: action == "stop" ? stopTimeout : replyTimeout) { try await call(action) }
        if action != "status" { DictationLog.write("dictation-\(action)-reply") }
        return reply
    }
    public func start() {
        guard phase == "idle" else { return }
        generation += 1; let session = generation
        phase = "starting"; error = nil; before = text()
        release("dictation-start")
        let priorCancellation = cancellation
        startTask = Task {
            await priorCancellation?.value
            guard session == generation else { return }
            do {
                try await focus()
                guard session == generation else { return }
                // The previous cancellation may finish while this start waits. Its timestamp
                // belongs to the old recording, even when the user already opened a new comment.
                started = Date().timeIntervalSince1970 * 1000
                try check(try await request("start"))
                guard session == generation else { return }
                phase = "recording"
                watchTask = Task { await watch(session) }
            } catch { fail(error, session: session, reason: "start-failed") }
        }
    }
    public func cancel() {
        let active = phase != "idle"
        generation += 1; phase = "idle"; error = nil
        watchTask?.cancel()
        release("cancel")
        guard active else { return }
        // Start has a short hard deadline. Serialize cleanup before the next recording.
        let start = startTask
        cancellation = Task {
            await start?.value
            do {
                let reply = try await request("cancel")
                if reply["result"].string != "noDictation" { try check(reply) }
            } catch {
                DictationLog.write("dictation-cancel-failed")
                reportError("Could not cancel Operator. Check Operator before trying again.")
            }
        }
    }
    private func fail(_ failure: Error, session: Int, reason: String) {
        guard session == generation else { return }
        cancel()
        error = failure is CancellationError ? "Dictation cancelled. Type your comment or try again." : failure.localizedDescription
        release(reason)
    }
    /// Returns only after a paste has settled; a failed dictation never submits stale text.
    public func finish() async throws {
        let session = generation
        defer { release("finish-exit") }
        do {
            try await withTaskCancellationHandler {
                await startTask?.value
                try Task.checkCancellation()
                guard session == generation else { throw CancellationError() }
                if phase == "recording" {
                    phase = "transcribing"; watchTask?.cancel()
                    try await focus()
                    try check(try await request("stop"))
                    guard try await waitForPaste(session) else { throw BridgeError("Operator sent no text to the comment. Try again or type your comment.") }
                    guard session == generation else { throw CancellationError() }
                    phase = "idle"; error = nil
                } else if phase == "transcribing" { await watchTask?.value }
                try Task.checkCancellation()
                guard session == generation else { throw BridgeError(error ?? "Dictation cancelled.") }
                if let error, text() == before { throw BridgeError(error) }
                error = nil
            } onCancel: {
                Task { @MainActor in self.fail(CancellationError(), session: session, reason: "task-cancelled") }
            }
        } catch {
            fail(error, session: session, reason: "finish-failed")
            throw error
        }
    }
    private func watch(_ session: Int) async {
        var lastState = ""
        var changed = ContinuousClock.now
        let began = ContinuousClock.now
        do {
            while session == generation {
                try await sleep(.milliseconds(150))
                guard !Task.isCancelled else { return }
                let reply = try await request("status")
                guard session == generation, !Task.isCancelled else { return }
                if reply["cancelledAt"].double >= started {
                    generation += 1; phase = "idle"
                    error = "Operator cancelled dictation. Type your comment or try again."
                    release("operator-cancelled")
                    return
                }
                try check(reply)
                let state = reply["status"].string
                guard ["starting", "idle", "ready", "loading", "arming", "recording", "transcribing"].contains(state) else {
                    throw BridgeError("Operator sent an unknown status. Try again or type your comment.")
                }
                if state != lastState { lastState = state; changed = .now; DictationLog.write("dictation-state-\(state)") }
                if began.duration(to: .now) > recordingLimit || (state != "recording" && changed.duration(to: .now) > progressTimeout) {
                    DictationLog.write("dictation-progress-timeout")
                    throw BridgeError("Operator stopped making progress. Try again or type your comment.")
                }
                if ["starting", "loading", "arming", "recording"].contains(state) { continue }
                phase = "transcribing"
                if state == "transcribing" { continue }
                guard try await waitForPaste(session) else { throw BridgeError("Operator finished without text. Try again or type your comment.") }
                guard session == generation else { return }
                phase = "idle"; error = nil; release("paste-complete"); return
            }
        } catch is CancellationError {
            // finish() cancels this poller deliberately and owns cleanup from that point.
            if !Task.isCancelled { fail(CancellationError(), session: session, reason: "status-cancelled") }
        } catch { fail(error, session: session, reason: "watch-failed") }
    }
    private func waitForPaste(_ session: Int) async throws -> Bool {
        for _ in 0..<60 {
            try Task.checkCancellation()
            guard session == generation else { throw CancellationError() }
            if text() != before {
                let previous = text(); try await sleep(.milliseconds(250))
                if text() == previous { return session == generation }
            }
            try await sleep(.milliseconds(50))
        }
        DictationLog.write("dictation-paste-missing")
        return false
    }
    private func check(_ reply: JSON) throws {
        let result = reply["result"].string
        if result == "ok" { return }
        let message: String
        switch result {
        case "silence": message = "Operator heard only silence."
        case "noDictation": message = "No active dictation, or focus changed."
        case "notRunning": message = "Operator is not running or its Local API is unavailable."
        case "unauthorized": message = "Operator rejected its Local API token. Check Operator Settings."
        default: message = reply["message"].string.isEmpty ? "Operator stopped answering." : reply["message"].string
        }
        throw BridgeError(message)
    }
}
