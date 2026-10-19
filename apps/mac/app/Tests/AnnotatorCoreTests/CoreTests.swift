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
@MainActor @Test func finishWaitsForStartAndPaste() async throws {
    let voice = Dictation(); var text = "Before"; var calls: [String] = []
    voice.text = { text }
    voice.call = { action in
        if action == "status" { return .object(["result": .string("ok"), "status": .string("recording")]) }
        calls.append(action)
        if action == "start" { try await Task.sleep(for: .milliseconds(20)) }
        if action == "stop" { text = "Before. Dictated text." }
        return .object(["result": .string("ok")])
    }
    voice.sleep = { duration in
        if duration == .milliseconds(150) { try await Task.sleep(for: .seconds(10)) }
        else { await Task.yield() }
    }
    voice.start()
    try await voice.finish()
    #expect(calls.prefix(2) == ["start", "stop"])
    #expect(voice.phase == "idle")
    #expect(text == "Before. Dictated text.")
}
@MainActor @Test func silenceKeepsCommentAndBlocksStaleSubmission() async {
    let voice = Dictation()
    voice.text = { "Existing comment" }
    voice.call = { action in .object(["result": .string(action == "stop" ? "silence" : "ok")]) }
    voice.sleep = { _ in try await Task.sleep(for: .seconds(10)) }
    voice.start()
    do { try await voice.finish(); Issue.record("Silence must block submission") } catch { #expect(error.localizedDescription.contains("silence")) }
    #expect(voice.phase == "idle")
}
@MainActor @Test func cancellationWaitsForStartBeforeNextRecording() async throws {
    let voice = Dictation(); var calls: [String] = []
    voice.call = { action in
        calls.append(action)
        if action == "start" { try await Task.sleep(for: .milliseconds(15)) }
        return .object(["result": .string("ok")])
    }
    voice.start(); await Task.yield(); voice.cancel(); voice.start()
    try await Task.sleep(for: .milliseconds(80))
    #expect(calls.prefix(3) == ["start", "cancel", "start"])
    voice.cancel()
}

@MainActor @Test func previousCancellationDoesNotCancelTheNextRecording() async throws {
    let voice = Dictation()
    var cancelledAt = 0.0
    var starts = 0
    var finishCancellation: CheckedContinuation<Void, Never>?
    voice.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    voice.call = { action in
        if action == "start" { starts += 1 }
        if action == "cancel" {
            await withCheckedContinuation { finishCancellation = $0 }
            cancelledAt = Date().timeIntervalSince1970 * 1000
        }
        return .object(["result": .string("ok"), "status": .string("recording"), "cancelledAt": .number(cancelledAt)])
    }
    voice.start()
    try await waitUntil { voice.phase == "recording" }
    voice.cancel()
    try await waitUntil { finishCancellation != nil }
    voice.start()
    try await Task.sleep(for: .milliseconds(20))
    finishCancellation?.resume(); finishCancellation = nil
    try await waitUntil { starts == 2 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(voice.phase == "recording")
    #expect(voice.error == nil)
    voice.cancel()
    try await waitUntil { finishCancellation != nil }
    finishCancellation?.resume()
}

@MainActor @Test func operatorCancellationKeepsTheDraftAndDoesNotSendAnotherCancel() async throws {
    let voice = Dictation()
    var calls: [String] = []
    var released: [String] = []
    var text = "Keep this draft"
    voice.text = { text }
    voice.releaseOverlay = { released.append($0) }
    voice.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    voice.call = { action in
        calls.append(action)
        return .object(["result": .string("ok"), "status": .string("ready"),
                        "cancelledAt": .number(Date().timeIntervalSince1970 * 1000)])
    }
    voice.start()
    try await waitUntil { voice.error != nil }
    #expect(voice.phase == "idle")
    #expect(voice.error?.contains("cancelled dictation") == true)
    #expect(voice.text() == "Keep this draft")
    #expect(released.contains("operator-cancelled"))
    #expect(!calls.contains("cancel"))
    text += ". Typed recovery."
    try await voice.finish()
    #expect(voice.error == nil)
}
@MainActor @Test func lostPasteDoesNotSubmit() async {
    let voice = Dictation(); voice.text = { "Unchanged" }
    voice.call = { _ in .object(["result": .string("ok")]) }
    voice.sleep = { duration in
        if duration == .milliseconds(150) { try await Task.sleep(for: .seconds(10)) }
        else { await Task.yield() }
    }
    voice.start()
    do { try await voice.finish(); Issue.record("A missing paste must block submission") } catch { #expect(error.localizedDescription.contains("no text")) }
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

@MainActor @Test func noReplyWatchdogReleasesAndCancels() async throws {
    let voice = Dictation(); var releases: [String] = []; var calls: [String] = []
    voice.replyTimeout = .milliseconds(30)
    voice.releaseOverlay = { releases.append($0) }
    voice.call = { action in
        calls.append(action)
        if action == "start" { try await Task.sleep(for: .seconds(5)) }
        return .object(["result": .string("ok")])
    }
    voice.start()
    try await waitUntil { calls.contains("cancel") }
    #expect(voice.phase == "idle")
    #expect(voice.error?.contains("in time") == true)
    #expect(releases.contains("start-failed"))
}

@MainActor @Test func escapeReleasesImmediatelyDuringSlowStart() async throws {
    let voice = Dictation(); var released = false; var calls: [String] = []
    voice.releaseOverlay = { _ in released = true }
    voice.call = { action in
        calls.append(action)
        if action == "start" { try await Task.sleep(for: .milliseconds(80)) }
        return .object(["result": .string("ok")])
    }
    voice.start(); await Task.yield(); released = false
    voice.cancel()
    #expect(released)
    #expect(voice.phase == "idle")
    try await waitUntil { calls.contains("cancel") }
    #expect(calls == ["start", "cancel"])
    #expect(voice.phase == "idle")
}

@MainActor @Test func stopTaskCancellationReleasesScreen() async throws {
    let voice = Dictation(); var stopping = false; var reasons: [String] = []; var cancelled = false
    voice.releaseOverlay = { reasons.append($0) }
    voice.call = { action in
        if action == "stop" { stopping = true; try await Task.sleep(for: .seconds(10)) }
        if action == "cancel" { cancelled = true }
        return .object(["result": .string("ok"), "status": .string("recording")])
    }
    voice.start()
    let finish = Task { try await voice.finish() }
    try await waitUntil { stopping }; finish.cancel()
    do { try await finish.value; Issue.record("Cancelled finish succeeded") } catch {}
    try await waitUntil { cancelled }
    #expect(voice.phase == "idle")
    #expect(reasons.contains("finish-exit"))
}

@MainActor @Test func failedStopAllowsTypingAndRetry() async throws {
    for result in ["silence", "notRunning", "unauthorized", "noDictation", "failed"] {
        let voice = Dictation(); var text = ""; var reasons: [String] = []
        voice.text = { text }; voice.releaseOverlay = { reasons.append($0) }
        voice.call = { action in .object(["result": .string(action == "stop" ? result : "ok")]) }
        voice.start()
        do { try await voice.finish(); Issue.record("Failure submitted") } catch {}
        #expect(reasons.contains("finish-failed"))
        #expect(voice.error != nil)
        text = "Typed after the failure"
        try await voice.finish()
        #expect(voice.error == nil)
    }
}

@MainActor @Test func statusFailureAndStalledProgressRelease() async throws {
    for state in ["transcribing", "loading", "unknown", "dropped"] {
        let voice = Dictation(); var cancelled = false
        voice.progressTimeout = .milliseconds(20)
        voice.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
        voice.call = { action in
            if action == "cancel" { cancelled = true }
            if action == "status", state == "dropped" { throw BridgeError("Connection dropped") }
            return .object(["result": .string("ok"), "status": .string(state)])
        }
        voice.start()
        try await waitUntil { cancelled }
        #expect(voice.phase == "idle")
        #expect(voice.error != nil)
    }
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

@MainActor @Test func focusFailureNeverStartsOperator() async throws {
    let voice = Dictation(); var calls: [String] = []
    voice.focus = { throw BridgeError("No focus") }
    voice.call = { calls.append($0); return .object(["result": .string("ok")]) }
    voice.start()
    try await waitUntil { voice.error != nil }
    #expect(!calls.contains("start"))
    #expect(voice.phase == "idle")
}

@MainActor @Test func stopDeadlineAndMissingPasteReleaseAndKeepDraft() async throws {
    for slow in [true, false] {
        let voice = Dictation(); var calls: [String] = []; var releases: [String] = []
        voice.stopTimeout = .milliseconds(25)
        voice.releaseOverlay = { releases.append($0) }
        voice.text = { "Draft" }
        voice.sleep = { duration in
            if duration == .milliseconds(150) { try await Task.sleep(for: .seconds(10)) }
            else { await Task.yield() }
        }
        voice.call = { action in
            calls.append(action)
            if action == "stop", slow { try await Task.sleep(for: .seconds(10)) }
            return .object(["result": .string("ok")])
        }
        voice.start()
        do { try await voice.finish(); Issue.record("No paste must fail") } catch {}
        try await waitUntil { calls.contains("cancel") }
        #expect(releases.contains("finish-failed"))
        #expect(voice.text() == "Draft")
        #expect(voice.phase == "idle")
        #expect(voice.error?.contains(slow ? "in time" : "no text") == true)
    }
}

@MainActor @Test func coreCrashReleasesDictation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("core")
    try "#!/bin/sh\nread request\nexit 1\n".write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let bridge = Bridge(), voice = Dictation(); var releases: [String] = []
    try bridge.start(executable: fixture)
    voice.call = { try await bridge.request("operator", .object(["action": .string($0)])) }
    voice.releaseOverlay = { releases.append($0) }
    voice.start()
    try await waitUntil { voice.error != nil }
    #expect(voice.phase == "idle")
    #expect(releases.contains("start-failed"))
    bridge.stop()
}
