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
