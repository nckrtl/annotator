#if DEBUG
import AppKit
import AnnotatorCore

/// Exercises the production panel and text view with a fake Local API. No real recording or user data.
@MainActor enum DictationCheck {
    private static func editor(in view: NSView?) -> NSTextView? {
        if let field = view as? NSTextView { return field }
        for child in view?.subviews ?? [] { if let field = editor(in: child) { return field } }
        return nil
    }
    static func run(_ model: AppModel, directory: String) async {
        do {
            guard model.demo, let panels = model.panels else { throw BridgeError("Run with ANNOTATOR_UI_DEMO=1") }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            var calls: [String] = []
            var releases: [String] = []
            model.voice.releaseOverlay = { releases.append($0) }
            model.voice.call = { action in
                calls.append(action)
                return .object(["result": .string("ok"), "status": .string("recording")])
            }
            let panel = panels.makeComment()
            panel.center(); panels.focusComment()
            try await Task.sleep(for: .milliseconds(200))
            panel.contentView?.layoutSubtreeIfNeeded(); panels.focusComment()
            let unfocused = ProcessInfo.processInfo.environment["ANNOTATOR_DICTATION_CHECK_UNFOCUSED"] == "1"
            if unfocused { model.voice.focus = {} }
            else { try await panels.prepareDictation() }
            guard !panel.styleMask.contains(.nonactivatingPanel), let field = unfocused ? editor(in: panel.contentView) : panel.firstResponder as? NSTextView else {
                throw BridgeError("Comment is not an activating text panel")
            }
            model.startDictation()
            // 200 acknowledges paste dispatch, not that the target field received it.
            do { try await model.finishDictation(); throw BridgeError("Missing paste succeeded") }
            catch { guard model.voice.error?.contains("no text") == true else { throw error } }
            guard panel.isVisible, field.isEditable, releases.contains("finish-failed") else {
                throw BridgeError("Failure did not preserve an editable draft and release the overlay")
            }
            field.insertText("Typed after the failed paste", replacementRange: NSRange(location: NSNotFound, length: 0))
            guard model.comment == "Typed after the failed paste" else { throw BridgeError("Typing did not reach the draft") }
            try await model.finishDictation()
            guard model.voice.error == nil else { throw BridgeError("Typing did not recover submission") }
            model.voice.call = { action in
                calls.append(action)
                if action == "stop" {
                    let board = NSPasteboard.general
                    let saved = (board.pasteboardItems ?? []).map { item in
                        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                    }
                    defer {
                        board.clearContents()
                        board.writeObjects(saved.map { fields in
                            let item = NSPasteboardItem()
                            for (type, data) in fields { item.setData(data, forType: type) }
                            return item
                        })
                    }
                    board.clearContents(); board.setString(" Fixture paste.", forType: .string)
                    if unfocused { field.paste(nil) }
                    else if !NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                        throw BridgeError("Paste action did not reach the responder chain")
                    }
                }
                return .object(["result": .string("ok"), "status": .string("recording")])
            }
            model.startDictation()
            try await model.finishDictation()
            guard model.comment.contains("Fixture paste.") else { throw BridgeError("Paste did not reach the comment") }
            // Route Escape through the same NSTextView command delegate as a real key.
            _ = field.delegate?.textView?(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            guard !panel.isVisible, model.voice.phase == "idle" else { throw BridgeError("Escape left the panel open") }
            try await Task.sleep(for: .milliseconds(50))
            guard calls.contains("cancel") else { throw BridgeError("Failure did not cancel Operator") }
            try await DictationFrames.capture(model, directory: directory, unfocused: unfocused)
            let focus = unfocused ? "SKIPPED real focus: explicit unfocused fixture mode." : "PASS: frontmost Annotator PID and key text field."
            let report = "PASS: activating panel, editable text view, missing-paste error, overlay release, typing recovery, responder paste, Escape closes. API actions: \(calls.joined(separator: ", ")).\n\(focus)\n"
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
