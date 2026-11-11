#if DEBUG
import AppKit
import AnnotatorCore

/// Answers Operator caller-session calls like Operator does: a wait answers when the session
/// ends, with the same transcript as its stop. No recording, clipboard or user data.
@MainActor final class FakeOperator {
    var startResult = "ok"
    var transcript = "Fixture transcript."
    var beforeStop: () async throws -> Void = {}
    private(set) var calls: [String] = []
    private var waits: [String: CheckedContinuation<JSON, Never>] = [:]
    static func result(_ name: String, text: String? = nil) -> JSON {
        .object(["result": .string(name)].merging(text.map { ["text": .string($0)] } ?? [:]) { $1 })
    }
    func reply(_ action: String, _ session: String) async throws -> JSON {
        calls.append("\(action) \(session)")
        switch action {
        case "start": return Self.result(startResult)
        case "wait": return await withCheckedContinuation { waits[session] = $0 }
        case "stop": try await beforeStop(); end(session); return Self.result("text", text: transcript)
        default: end(session, Self.result("conflict")); return Self.result("ok")
        }
    }
    /// Operator's own shortcut ended the recording, or a stop or cancel did.
    func end(_ session: String, _ reply: JSON? = nil) {
        waits.removeValue(forKey: session)?.resume(returning: reply ?? Self.result("text", text: transcript))
    }
}

/// Exercises the production panel and text view with a fake Local API.
@MainActor enum DictationCheck {
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw BridgeError("Timed out")
    }
    static func run(_ model: AppModel, directory: String) async {
        do {
            guard model.demo, let panels = model.panels else { throw BridgeError("Run with ANNOTATOR_UI_DEMO=1") }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            var handed: [String] = []
            model.demoRequest = { command, args in
                if command == "submit_comment" { handed.append(args["text"]!.string + "|" + args["session"]!.string) }
                return .null
            }
            let fake = FakeOperator()
            model.voice.call = { try await fake.reply($0, $1) }
            func open(_ id: String) async throws -> NSTextView {
                model.target = .object(["annotationId": .string(id), "label": .string("Fixture · Save"), "mode": .string("element"), "dictation": .object(["autoStart": .bool(false)])])
                model.comment = ""; model.commentError = nil; model.voice.open(id)
                let panel = panels.commentPanel ?? panels.makeComment()
                panel.center(); panels.focusComment()
                try await Task.sleep(for: .milliseconds(200))
                guard !panel.styleMask.contains(.nonactivatingPanel), let field = panels.commentField, field.isEditable else {
                    throw BridgeError("Comment is not an activating text panel")
                }
                return field
            }
            func dictate() async throws {
                model.startDictation()
                try await until { model.dictation == "recording" }
            }
            // Stop button: the transcript lands at the caret once, after one space.
            var field = try await open("check")
            field.insertText("Typed", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await dictate(); model.stopDictation()
            try await until { model.dictation == "idle" }
            try await Task.sleep(for: .milliseconds(100))
            guard model.comment == "Typed Fixture transcript." else { throw BridgeError("Stop did not insert the transcript once at the caret") }
            // Operator's shortcut: the wait answers, and the transcript replaces the selection.
            field.setSelectedRange(NSRange(location: 0, length: 5))
            fake.transcript = "Spoken"
            try await dictate(); fake.end("check-2")
            try await until { model.dictation == "idle" }
            guard model.comment == "Spoken Fixture transcript." else { throw BridgeError("The shortcut path did not replace the selection") }
            // An Operator without sessions: the error stays beside an editable field.
            fake.startResult = "unsupported"
            model.startDictation()
            try await until { model.voice.error != nil }
            guard model.voice.error == "Update Operator to dictate in Annotator.", panels.commentPanel?.isVisible == true, field.isEditable else {
                throw BridgeError("A start failure did not keep an editable draft")
            }
            field.insertText(" Typed after.", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard model.comment == "Spoken Typed after. Fixture transcript." else { throw BridgeError("Typing did not reach the draft at the caret") }
            fake.startResult = "ok"
            // Escape cancels only this box's session and closes the panel.
            try await dictate()
            _ = field.delegate?.textView?(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            guard panels.commentPanel?.isVisible == false, model.voice.phase == "idle" else { throw BridgeError("Escape left the panel open") }
            try await until { fake.calls.contains("cancel check-4") }
            // Submit while recording hands the session to the core and never cancels it.
            field = try await open("next")
            field.insertText("Typed", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await dictate()
            await model.submit()
            try await Task.sleep(for: .milliseconds(100))
            guard handed == ["Typed|next-1"], !fake.calls.contains(where: { $0.hasPrefix("cancel next") }), model.voice.session == nil else {
                throw BridgeError("Submit did not hand off the live session")
            }
            fake.end("next-1")
            try await Task.sleep(for: .milliseconds(100))
            guard model.comment == "Typed" else { throw BridgeError("A handed-off transcript reached the box") }
            try await DictationFrames.capture(model, directory: directory)
            let report = "PASS: activating panel, insert at caret once (stop and wait), selection replaced, start error keeps an editable draft, Escape cancels its session, Submit hands off the live session. API calls: \(fake.calls.joined(separator: ", ")).\n"
            try report.write(toFile: directory + "/dictation-panel-check.txt", atomically: true, encoding: .utf8)
            print(report)
            NSApp.terminate(nil)
        } catch {
            try? "FAIL: \(error)\n".write(toFile: directory + "/dictation-panel-check.txt", atomically: true, encoding: .utf8)
            fputs("Dictation panel check failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
