import Foundation
import Testing
@testable import AnnotatorCore

@Test func pipeFramesSplitUnicodeAndMultipleReplies() throws {
    var frames = Lines()
    let data = Data("{\"event\":\"state\",\"payload\":\"⌃⌥A\"}\n{\"id\":\"2\",\"result\":null}\n".utf8)
    var replies: [JSON] = []
    for byte in data { replies += try frames.append(Data([byte])) }
    #expect(replies.count == 2)
    #expect(replies[0]["payload"].string == "⌃⌥A")
    #expect(replies[1]["result"] == .null)
}
@Test func malformedReplyIsNotSilentlyIgnored() {
    var frames = Lines()
    #expect(throws: (any Error).self) { _ = try frames.append(Data("not JSON\n".utf8)) }
}
@Test func projectNamesCannotCollideWithNavigation() {
    let project: JSON = .object(["id": .string("p1"), "name": .string("settings")])
    let item: JSON = .object(["number": .number(1), "comment": .string("Fix the BUTTON"), "status": .string("todo"), "native": .object(["project": .string("settings")])])
    #expect(AnnotationCollection.items([item], page: "settings", projects: [project], search: "").isEmpty)
    #expect(AnnotationCollection.items([item], page: "project:p1", projects: [project], search: "button") == [item])
    #expect(AnnotationCollection.items([item], page: "done", projects: [project], search: "").isEmpty)
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition did not arrive within one second")
}

@MainActor @Test func deadlineDoesNotWaitForAnUncooperativeTransport() async throws {
    var reply: CheckedContinuation<JSON, Error>?
    let deadline = Deadline()
    do {
        _ = try await deadline.run(after: .milliseconds(20)) {
            try await withCheckedThrowingContinuation { reply = $0 }
        }
        Issue.record("Silent API succeeded")
    } catch { #expect(error.localizedDescription.contains("in time")) }
    // A reply after timeout must neither resume twice nor revive the recording.
    reply?.resume(returning: .null)
}

@Test func cancelledAnnotationsAreFinished() {
    let items: [JSON] = ["todo", "in_progress", "done", "cancelled"].enumerated().map { .object(["number": .number(Double($0.offset)), "status": .string($0.element)]) }
    #expect(items.filter(AnnotationCollection.isOpen).map { $0["status"].string } == ["todo", "in_progress"])
    #expect(AnnotationCollection.items(items, page: "done", projects: [], search: "").map { $0["status"].string } == ["cancelled", "done"])
    #expect(AnnotationCollection.items(items, page: "open", projects: [], search: "").map { $0["status"].string } == ["in_progress", "todo"])
    #expect(AnnotationCollection.statusTitle("cancelled") == "Cancelled")
}

// MARK: - Dictation with Operator caller sessions

/// Answers like Operator: a wait answers when the session ends, with the same reply as its stop.
@MainActor private final class FakeOperator {
    var calls: [String] = []
    var start: JSON = reply("ok")
    var stop: JSON = reply("text", "Spoken")
    var startDelay: Duration = .zero
    var waits: [JSON] = []
    private var pending: [String: CheckedContinuation<JSON, Never>] = [:]
    static func reply(_ result: String, _ text: String? = nil) -> JSON {
        .object(["result": .string(result)].merging(text.map { ["text": .string($0)] } ?? [:]) { $1 })
    }
    func call(_ action: String, _ session: String) async throws -> JSON {
        calls.append("\(action) \(session)")
        switch action {
        case "start": if startDelay > .zero { try await Task.sleep(for: startDelay) }; return start
        case "wait":
            if !waits.isEmpty { return waits.removeFirst() }
            return await withCheckedContinuation { pending[session] = $0 }
        case "stop": end(session, stop); return stop
        default: end(session, Self.reply("conflict")); return Self.reply("ok")
        }
    }
    func end(_ session: String, _ reply: JSON) { pending.removeValue(forKey: session)?.resume(returning: reply) }
    var waiting: Bool { !pending.isEmpty }
}

@MainActor private func dictation(_ fake: FakeOperator, inserted: @escaping (String) -> Void = { _ in }) -> Dictation {
    let voice = Dictation()
    voice.call = { try await fake.call($0, $1) }
    voice.insert = inserted
    voice.open("a1")
    return voice
}

@MainActor @Test func startThenWaitInsertsTheTranscriptOnce() async throws {
    let fake = FakeOperator(); var inserted: [String] = []; var succeeded = 0
    let voice = dictation(fake) { inserted.append($0) }
    voice.succeeded = { succeeded += 1 }
    voice.start()
    #expect(voice.phase == "starting")
    try await waitUntil { fake.waiting }
    #expect(voice.phase == "recording" && voice.session == "a1-1")
    voice.stop()
    #expect(voice.phase == "transcribing")
    try await waitUntil { voice.phase == "idle" }
    try await Task.sleep(for: .milliseconds(30))
    #expect(inserted == ["Spoken"])
    #expect(succeeded == 1)
    #expect(fake.calls == ["start a1-1", "wait a1-1", "stop a1-1"])
    // Operator accepts a session id once: the next recording in this box uses a new one.
    voice.start()
    try await waitUntil { fake.waiting }
    #expect(voice.session == "a1-2")
    voice.cancel()
}

@MainActor @Test func operatorShortcutEndsTheRecordingThroughWait() async throws {
    let fake = FakeOperator(); var inserted: [String] = []
    let voice = dictation(fake) { inserted.append($0) }
    voice.start()
    try await waitUntil { fake.waiting }
    fake.end("a1-1", FakeOperator.reply("text", " From the shortcut "))
    try await waitUntil { voice.phase == "idle" }
    #expect(inserted == ["From the shortcut"])
    #expect(!fake.calls.contains { $0.hasPrefix("stop") })
}

@MainActor @Test func waitThatTimesOutIsSentAgain() async throws {
    let fake = FakeOperator(); var inserted: [String] = []
    fake.waits = [FakeOperator.reply("timedOut"), FakeOperator.reply("timedOut"), FakeOperator.reply("text", "Late")]
    let voice = dictation(fake) { inserted.append($0) }
    voice.start()
    try await waitUntil { voice.phase == "idle" && !inserted.isEmpty }
    #expect(inserted == ["Late"])
    #expect(fake.calls == ["start a1-1", "wait a1-1", "wait a1-1", "wait a1-1"])
}

@MainActor @Test func cancelDuringStartGoesOutAfterTheStartAnswers() async throws {
    let fake = FakeOperator(); fake.startDelay = .milliseconds(40)
    let voice = dictation(fake)
    voice.start(); await Task.yield()
    voice.cancel()
    #expect(voice.phase == "idle" && voice.session == nil)
    try await waitUntil { fake.calls.count == 2 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(fake.calls == ["start a1-1", "cancel a1-1"])
}

@MainActor @Test func submitHandsOffTheLiveSessionAndNeverCancelsIt() async throws {
    let fake = FakeOperator(); var inserted: [String] = []
    let voice = dictation(fake) { inserted.append($0) }
    voice.start()
    try await waitUntil { fake.waiting }
    #expect(await voice.detach() == "a1-1")
    #expect(voice.phase == "idle" && voice.session == nil)
    voice.cancel()
    fake.end("a1-1", FakeOperator.reply("text", "For the core"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(inserted.isEmpty)
    #expect(!fake.calls.contains { $0.hasPrefix("cancel") || $0.hasPrefix("stop") })
    // A hand-off during start waits for the start; a failed start hands nothing off.
    fake.startDelay = .milliseconds(20)
    voice.start(); await Task.yield()
    #expect(await voice.detach() == "a1-2")
    fake.start = FakeOperator.reply("conflict")
    voice.start(); await Task.yield()
    #expect(await voice.detach() == nil)
    #expect(await Dictation().detach() == nil)
}

@MainActor @Test func errorsKeepTheBoxUsable() async throws {
    let cases: [(String, JSON, JSON, String)] = [
        ("start", FakeOperator.reply("conflict"), .null, "Operator is busy. Try again."),
        ("start", FakeOperator.reply("unsupported"), .null, "Update Operator to dictate in Annotator."),
        ("start", FakeOperator.reply("notRunning"), .null, "Operator is not running or its Local API is unavailable."),
        ("start", FakeOperator.reply("unauthorized"), .null, "Operator rejected its Local API token. Check Operator Settings."),
        ("stop", .null, FakeOperator.reply("conflict"), "Operator cancelled dictation. Type your comment or try again."),
        ("stop", .null, FakeOperator.reply("unknown"), "Operator lost this dictation. Type your comment or try again."),
        ("stop", .null, FakeOperator.reply("text", "  "), "Operator heard no speech."),
        ("stop", .null, .object(["result": .string("failed"), "message": .string("500 Model failed")]), "500 Model failed"),
    ]
    for (step, start, stop, message) in cases {
        let fake = FakeOperator(); var inserted: [String] = []
        if start != .null { fake.start = start }
        if stop != .null { fake.stop = stop }
        let voice = dictation(fake) { inserted.append($0) }
        voice.start()
        if step == "stop" { try await waitUntil { fake.waiting }; voice.stop() }
        try await waitUntil { voice.error != nil }
        #expect(voice.error == message)
        #expect(voice.phase == "idle" && voice.session == nil && inserted.isEmpty)
        // The box stays usable: a new recording gets a new session.
        fake.start = FakeOperator.reply("ok"); fake.stop = FakeOperator.reply("text", "Again")
        voice.start()
        try await waitUntil { fake.waiting }
        #expect(voice.error == nil && voice.session == "a1-2")
        voice.cancel()
    }
}

@MainActor @Test func silentStartTimesOutAndCancelsOnlyItsSession() async throws {
    let fake = FakeOperator(); fake.startDelay = .seconds(5)
    let voice = dictation(fake)
    voice.replyTimeout = .milliseconds(30)
    voice.start()
    try await waitUntil { voice.error != nil }
    #expect(voice.error?.contains("in time") == true)
    try await waitUntil { fake.calls.contains("cancel a1-1") }
    #expect(voice.phase == "idle")
}

@MainActor @Test func recordingLimitStopsAndKeepsTheText() async throws {
    let fake = FakeOperator(); var inserted: [String] = []
    let voice = dictation(fake) { inserted.append($0) }
    voice.recordingLimit = .milliseconds(30)
    voice.start()
    try await waitUntil { !inserted.isEmpty }
    #expect(inserted == ["Spoken"] && voice.error == nil)
    #expect(fake.calls.contains("stop a1-1"))
}

@Test func transcriptSpacing() {
    #expect(Dictation.spaced("Hi", after: nil) == "Hi")
    #expect(Dictation.spaced("Hi", after: "a") == " Hi")
    #expect(Dictation.spaced("Hi", after: ".") == " Hi")
    #expect(Dictation.spaced("Hi", after: " ") == "Hi")
    #expect(Dictation.spaced("Hi", after: "\n") == "Hi")
}

@MainActor @Test func coreCrashFailsTheStart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("core")
    try "#!/bin/sh\nread request\nexit 1\n".write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let bridge = Bridge(), voice = Dictation()
    try bridge.start(executable: fixture)
    voice.call = { try await bridge.request("operator", .object(["action": .string($0), "session": .string($1)])) }
    voice.open("a1")
    voice.start()
    try await waitUntil { voice.error != nil }
    #expect(voice.phase == "idle")
    bridge.stop()
}
