#if DEBUG
import AppKit
import AnnotatorCore

/// Drives real windows with demo data. It never starts the core or the annotation server.
@MainActor enum WindowCheck {
    static func run(_ model: AppModel, directory: String) async {
        do {
            guard model.demo, let panels = model.panels else { throw BridgeError("Run with ANNOTATOR_UI_DEMO=1") }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try await settle()
            precondition(model.window?.isVisible != true, "Launch must leave the library hidden")
            model.navigate("all")
            try await settle()
            guard let library = model.window, library.isVisible else { throw BridgeError("Explicit navigation did not open the library") }
            let menu = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            menu.isReleasedWhenClosed = false
            panels.menu = menu
            menu.orderFront(nil)
            var lines = ["PASS: hidden at launch; explicit navigation opens library."]
            for appearance in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                model.navigate("all")
                menu.orderFront(nil)
                model.event("state", .object(["annotating": .bool(true)]))
                precondition(!library.isVisible && !menu.isVisible, "Starting capture must hide library and flyout")
                model.event("queue", .array(model.items))
                precondition(!library.isVisible, "Queue updates must not reopen library")
                model.event("comment-opened", .object(["label": .string("Fixture target"), "mode": .string("element")]))
                model.event("state", .object(["commentOpen": .bool(true)]))
                let panel = panels.commentPanel ?? panels.makeComment()
                panel.center()
                panels.focusComment()
                try await settle()
                precondition(panel.isVisible && !library.isVisible, "Comment activation must leave library hidden")
                if let view = panel.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "/\(appearance)-comment-offscreen.png"))
                }
                precondition(!panel.styleMask.contains(.nonactivatingPanel), "Dictation needs an activating panel")
                // Operator can reopen its paste target; that must not navigate to the library.
                let delegate = AppDelegate()
                precondition(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
                precondition(!library.isVisible)
                // Explicit navigation still works. Refocusing the comment hides it again.
                model.navigate("settings")
                try await settle()
                precondition(library.isVisible && model.page == "settings")
                panels.focusComment()
                try await settle()
                precondition(!library.isVisible && panel.isVisible)
                try await panels.prepareDictation()
                guard let field = panel.firstResponder as? NSTextView else { throw BridgeError("No comment editor") }
                field.insertText("Typed fixture", replacementRange: NSRange(location: NSNotFound, length: 0))
                precondition(model.comment == "Typed fixture", "Typing must still reach the draft")
                lines.append("PASS: \(appearance) frontmost Annotator, key comment editor and typing.")

                panels.hideComment()
                model.event("state", .object(["annotating": .bool(false), "commentOpen": .bool(false)]))
                precondition(!library.isVisible, "Finishing capture must not restore library")
                precondition(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
                try await settle()
                precondition(library.isVisible && model.page == "all", "Idle reopen must show library")
                library.close()
                model.navigate("all")
                try await settle()
                precondition(library.isVisible, "Closed library must reopen explicitly")
                lines.append("PASS: \(appearance) capture, queue, comment activation, reopen guard, refocus, finish and explicit navigation.")
            }
            panels.hideComment(); menu.close()
            let report = lines.joined(separator: "\n") + "\n"
            try report.write(toFile: directory + "/window-check.txt", atomically: true, encoding: .utf8)
            print(report)
            NSApp.terminate(nil)
        } catch {
            try? "FAIL: \(error)\n".write(toFile: directory + "/window-check.txt", atomically: true, encoding: .utf8)
            fputs("Window check failed: \(error)\n", stderr)
            exit(1)
        }
    }
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }
}
#endif
