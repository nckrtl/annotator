#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit
import DesignKit
import AnnotatorCore

/// Captures the real panel and dictation lifecycle; only Operator's replies and paste are fixtures.
@MainActor enum DictationFrames {
    static func capture(_ model: AppModel, directory: String, unfocused: Bool) async throws {
        guard let panels = model.panels else { throw BridgeError("Missing panels") }
        let frames = directory + "/frames"
        try FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        var report = ["ScreenCaptureKit window frames. Fake Operator replies and paste; no audio.",
                      "name,phase,seconds"]
        for appearance in ["light", "dark"] {
            for reduceMotion in [false, true] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                model.target = .object(["label": .string("Safari · Open project"), "mode": .string("element"), "dictation": .object(["autoStart": .bool(false)])])
                model.comment = ""; model.commentError = nil; model.demoDictation = nil
                let panel = panels.makeComment()
                panel.appearance = NSApp.appearance
                // The public environment getter is read-only; this SDK setter is debug-only.
                panel.contentView = NSHostingView(rootView: CommentView(model: model).kitAppearance()
                    .environment(\._accessibilityReduceMotion, reduceMotion))
                defer { panel.orderOut(nil) }
                panel.center(); panels.focusComment()
                try await Task.sleep(for: .milliseconds(250))
                if !unfocused { try await panels.prepareDictation() }
                let prefix = "\(appearance)-\(reduceMotion ? "reduced" : "motion")"
                let began = Date()
                func frame(_ name: String) async throws {
                    try await shot(panel, path: frames + "/\(prefix)-\(name).png")
                    report.append("\(prefix)-\(name),\(model.dictation),\(String(format: "%.3f", Date().timeIntervalSince(began)))")
                }
                model.voice.call = { action in
                    if action == "stop" {
                        guard model.dictation == "transcribing" else { throw BridgeError("Stop did not enter transcription") }
                        // Sample across more than one former microphone rotation (one second).
                        for index in 0..<10 {
                            try await Task.sleep(for: .milliseconds(170))
                            try await frame(String(format: "02-waiting-%02d", index))
                        }
                        try paste(in: panel, unfocused: unfocused)
                    }
                    return .object(["result": .string("ok"), "status": .string("recording")])
                }
                try await frame("00-idle")
                model.startDictation()
                for _ in 0..<100 {
                    if model.dictation != "starting" { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard model.dictation == "recording" else { throw BridgeError("Fixture did not start recording") }
                try await Task.sleep(for: .milliseconds(200))
                try await frame("01-recording")
                try await model.finishDictation()
                guard model.dictation == "idle", model.comment == "Make the button label easier to read." else {
                    throw BridgeError("Fixture paste did not settle")
                }
                try await Task.sleep(for: .milliseconds(200))
                try await frame("03-pasted")
            }
        }
        try report.joined(separator: "\n").write(toFile: frames + "/sequence.csv", atomically: true, encoding: .utf8)
    }

    private static func paste(in panel: NSPanel, unfocused: Bool) throws {
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
        board.clearContents(); board.setString("Make the button label easier to read.", forType: .string)
        if unfocused {
            func editor(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.compactMap { editor($0) }.first
            }
            guard let view = panel.contentView, let field = editor(view) else { throw BridgeError("Missing text view") }
            field.paste(nil)
        } else if !NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
            throw BridgeError("Paste did not reach the responder chain")
        }
    }

    private static func shot(_ panel: NSPanel, path: String) async throws {
        panel.contentView?.layoutSubtreeIfNeeded()
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
            throw BridgeError("Comment panel is not on screen")
        }
        let config = SCStreamConfiguration()
        config.width = Int(panel.frame.width * 2); config.height = Int(panel.frame.height * 2)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw BridgeError("Could not encode panel frame")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
