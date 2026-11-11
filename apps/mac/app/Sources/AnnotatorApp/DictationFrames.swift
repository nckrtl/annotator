#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit
import DesignKit
import AnnotatorCore

/// Captures the real panel and dictation lifecycle; only Operator's session replies are fixtures.
@MainActor enum DictationFrames {
    static func capture(_ model: AppModel, directory: String) async throws {
        guard let panels = model.panels else { throw BridgeError("Missing panels") }
        let frames = directory + "/frames"
        try FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        var report = ["ScreenCaptureKit window frames. Fake Operator session replies; no audio.",
                      "name,phase,seconds"]
        var round = 0
        for appearance in ["light", "dark"] {
            for reduceMotion in [false, true] {
                round += 1
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                model.target = .object(["label": .string("Safari · Open project"), "mode": .string("element"), "dictation": .object(["autoStart": .bool(false)])])
                model.comment = ""; model.commentError = nil; model.demoDictation = nil
                model.voice.open("frames\(round)")
                let panel = panels.makeComment()
                panel.appearance = NSApp.appearance
                // The public environment getter is read-only; this SDK setter is debug-only.
                panel.contentView = NSHostingView(rootView: CommentView(model: model).kitAppearance()
                    .environment(\._accessibilityReduceMotion, reduceMotion))
                defer { panel.orderOut(nil) }
                panel.center(); panels.focusComment()
                try await Task.sleep(for: .milliseconds(250))
                let prefix = "\(appearance)-\(reduceMotion ? "reduced" : "motion")"
                let began = Date()
                func frame(_ name: String) async throws {
                    try await shot(panel, path: frames + "/\(prefix)-\(name).png")
                    report.append("\(prefix)-\(name),\(model.dictation),\(String(format: "%.3f", Date().timeIntervalSince(began)))")
                }
                let fake = FakeOperator()
                fake.transcript = "Make the button label easier to read."
                fake.beforeStop = {
                    guard model.dictation == "transcribing" else { throw BridgeError("Stop did not show transcription") }
                    for index in 0..<10 {
                        try await Task.sleep(for: .milliseconds(170))
                        try await frame(String(format: "02-waiting-%02d", index))
                    }
                }
                model.voice.call = { try await fake.reply($0, $1) }
                try await frame("00-idle")
                model.startDictation()
                try await DictationCheck.until { model.dictation != "starting" }
                guard model.dictation == "recording" else { throw BridgeError("Fixture did not start recording") }
                try await Task.sleep(for: .milliseconds(200))
                try await frame("01-recording")
                model.stopDictation()
                for _ in 0..<500 where model.dictation != "idle" { try await Task.sleep(for: .milliseconds(10)) }
                guard model.dictation == "idle", model.comment == "Make the button label easier to read." else {
                    throw BridgeError("Fixture transcript did not arrive")
                }
                try await Task.sleep(for: .milliseconds(200))
                try await frame("03-inserted")
            }
        }
        try report.joined(separator: "\n").write(toFile: frames + "/sequence.csv", atomically: true, encoding: .utf8)
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
