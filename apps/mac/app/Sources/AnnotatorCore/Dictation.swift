import Foundation
import Observation

/// One comment box's Operator dictation. Each recording is a new caller session named
/// `<annotation id>-<n>`, because Operator accepts a session id once. Operator never pastes for a
/// session: stop and wait answer with the transcript, which the box inserts at the caret once.
@MainActor @Observable public final class Dictation {
    /// `idle`, `starting`, `recording` or `transcribing`.
    public private(set) var phase = "idle"
    public private(set) var error: String?
    /// The box's live session, from start until its transcript arrives, a cancel or a hand-off.
    public private(set) var session: String?
    @ObservationIgnored public var call: (_ action: String, _ session: String) async throws -> JSON = { _, _ in .null }
    @ObservationIgnored public var insert: (String) -> Void = { _ in }
    @ObservationIgnored public var succeeded: () -> Void = {}
    @ObservationIgnored public var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    // Injectable deadlines keep failure tests fast.
    @ObservationIgnored public var replyTimeout: Duration = .seconds(5)
    @ObservationIgnored public var transcriptTimeout: Duration = .seconds(130)
    @ObservationIgnored public var recordingLimit: Duration = .seconds(120)
    /// Answers whether the start succeeded. A cancel or a hand-off waits for it.
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    private var annotation = ""
    private var count = 0
    public init() {}

    /// A new comment box. Its sessions are named after the annotation id.
    public func open(_ annotation: String) {
        cancel()
        self.annotation = annotation; count = 0; error = nil
    }
    private static let results: Set = ["ok", "text", "conflict", "unknown", "unsupported", "timedOut", "notRunning", "unauthorized", "failed"]
    private func request(_ action: String, _ session: String) async throws -> JSON {
        // Action comes only from this class. The log keeps step codes, never text.
        DictationLog.write("session-\(action)")
        let call = self.call
        let reply = try await Deadline().run(after: ["stop", "wait"].contains(action) ? transcriptTimeout : replyTimeout) { try await call(action, session) }
        DictationLog.write("session-\(action)-\(Self.results.contains(reply["result"].string) ? reply["result"].string : "other")")
        return reply
    }
    public func start() {
        guard phase == "idle", session == nil, !annotation.isEmpty else { return }
        count += 1
        let session = "\(annotation)-\(count)"
        self.session = session; phase = "starting"; error = nil
        startTask = Task {
            let reply: JSON
            do { reply = try await request("start", session) } catch {
                // No answer: Operator may have started. End only this session.
                Task { _ = try? await self.request("cancel", session) }
                fail(error, session); return false
            }
            do { try check(reply, "start") } catch { fail(error, session); return false }
            // A cancel or a hand-off during start now owns the session.
            guard self.session == session else { return true }
            phase = "recording"
            tasks.append(Task { await waitForText(session) })
            tasks.append(Task {
                guard (try? await sleep(recordingLimit)) != nil, self.session == session, phase == "recording" else { return }
                DictationLog.write("session-limit"); stop()
            })
            return true
        }
    }
    /// The stop button and the recording limit. The transcript arrives through stop or wait.
    public func stop() {
        guard phase == "recording", let session else { return }
        phase = "transcribing"
        tasks.append(Task {
            do {
                let reply = try await request("stop", session)
                // After a 504 the wait keeps running and answers when the transcript is final.
                if reply["result"].string != "timedOut" { deliver(reply, session) }
            } catch { if !(error is CancellationError) { fail(error, session) } }
        })
    }
    /// Escape and the close button. Cancels only this box's session, after its start answered.
    public func cancel() {
        guard let session else { return }
        end(); error = nil
        let start = startTask
        Task {
            guard await start?.value == true else { return }
            do {
                let reply = try await request("cancel", session)
                if !["ok", "unknown"].contains(reply["result"].string) { try check(reply, "cancel") }
            } catch { DictationLog.write("session-cancel-failed") }
        }
    }
    /// Submit or a move: hands the live session to the core, which stops it and posts the comment
    /// in the background. This box forgets the session and never cancels it. Waits only for a
    /// start in flight; nil when there is no session or its start failed.
    public func detach() async -> String? {
        guard let session else { return nil }
        end(); error = nil
        DictationLog.write("session-handoff")
        return await startTask?.value == true ? session : nil
    }
    private func waitForText(_ session: String) async {
        while self.session == session {
            do {
                let reply = try await request("wait", session)
                // Operator gives up on a wait after about 119 s; the recording goes on.
                if reply["result"].string == "timedOut" { continue }
                deliver(reply, session); return
            } catch { if !(error is CancellationError) { fail(error, session) }; return }
        }
    }
    /// Stop and wait can both answer with the same transcript; only the first one counts.
    private func deliver(_ reply: JSON, _ session: String) {
        guard self.session == session else { return }
        do { try check(reply, "stop") } catch { fail(error, session); return }
        end()
        let text = reply["text"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { error = "Operator heard no speech."; DictationLog.write("session-empty"); return }
        insert(text); DictationLog.write("session-inserted"); succeeded()
    }
    private func fail(_ failure: Error, _ session: String) {
        guard self.session == session else { return }
        end()
        error = failure is CancellationError ? "Dictation cancelled. Type your comment or try again." : failure.localizedDescription
    }
    private func end() {
        session = nil; phase = "idle"
        tasks.forEach { $0.cancel() }; tasks = []
    }
    private func check(_ reply: JSON, _ action: String) throws {
        let message: String
        switch reply["result"].string {
        case "ok", "text": return
        case "conflict": message = action == "start" ? "Operator is busy. Try again." : "Operator cancelled dictation. Type your comment or try again."
        case "unknown": message = "Operator lost this dictation. Type your comment or try again."
        case "unsupported": message = "Update Operator to dictate in Annotator."
        case "timedOut": message = "Operator did not finish in time. Type your comment or try again."
        case "notRunning": message = "Operator is not running or its Local API is unavailable."
        case "unauthorized": message = "Operator rejected its Local API token. Check Operator Settings."
        default: message = reply["message"].string.isEmpty ? "Operator stopped answering." : reply["message"].string
        }
        throw BridgeError(message)
    }
    /// The transcript as inserted at the caret: one space first when the character before the
    /// caret is not whitespace. `previous` is nil at the start of the field.
    nonisolated public static func spaced(_ text: String, after previous: Character?) -> String {
        guard let previous, !previous.isWhitespace else { return text }
        return " " + text
    }
}
