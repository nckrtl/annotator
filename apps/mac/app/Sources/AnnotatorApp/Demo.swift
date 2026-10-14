import SwiftUI
import AppKit
import AnnotatorCore
import DesignKit
import ScreenCaptureKit

@MainActor enum Demo {
    static var screenshot: String {
        let image = NSImage(size: NSSize(width: 760, height: 220))
        image.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 760, height: 220).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 28, y: 24, width: 704, height: 172), xRadius: 12, yRadius: 12).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.black]
        ("Project overview" as NSString).draw(at: NSPoint(x: 52, y: 134), withAttributes: title)
        ("Capture an idea. Give it the context it needs." as NSString).draw(at: NSPoint(x: 52, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray])
        NSColor.black.setFill(); NSBezierPath(roundedRect: NSRect(x: 52, y: 48, width: 140, height: 34), xRadius: 17, yRadius: 17).fill()
        ("Open project" as NSString).draw(at: NSPoint(x: 69, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        return "data:image/png;base64," + data.base64EncodedString()
    }
    static func populate(_ model: AppModel) {
        #if DEBUG
        model.settings = try! JSON.decode(Data(#"{"serverURL":"http://127.0.0.1:29703/annotations","serverAutoStart":true,"operatorEnabled":true,"operatorAutoStart":true,"hotkey":{"keyCode":0,"modifiers":6144}}"#.utf8))
        var project = newProject(); project["name"] = .string("Website"); project["root"] = .string("~/Projects/website"); project["bundleIds"] = .array([.string("com.apple.Safari")]); project["urlPrefixes"] = .array([.string("http://localhost:3000")]); project["id"] = .string("website"); project["instructions"] = .string("Run the local website with bun dev before checking annotations.")
        var native = newProject(); native["id"] = .string("desktop"); native["name"] = .string("Desktop app"); native["root"] = .string("~/Projects/desktop"); native["bundleIds"] = .array([.string("com.example.desktop")])
        var docs = newProject(); docs["id"] = .string("docs"); docs["name"] = .string("Documentation"); docs["urlPrefixes"] = .array([.string("https://docs.example.com")])
        model.projects = [project, native, docs]; model.selectedProjectID = ""
        model.items = [
            item(215, "Make the button label easier to read", "Safari", "todo"),
            item(214, "Align the title with the list below", "Finder", "in_progress"),
            item(213, "Keep this sidebar open after navigation", "Safari", "todo"),
            item(212, "Give the search field more space", "Notes", "done"),
            item(211, "Use a clearer empty-state message", "Safari", "done")
        ]
        model.items[1]["native"]["project"] = .string("Desktop app")
        model.items[3]["native"]["project"] = .string("Inbox")
        model.items[3]["summary"] = .string("Increased the search field width and kept the clear button visible.")
        model.state = try! JSON.decode(Data(#"{"health":{"tone":"ok","title":"Connected"},"serverURL":"http://127.0.0.1:29703/annotations","annotating":false,"permissions":{"accessibility":true,"screenRecording":true},"queue":{"todo":2,"inProgress":1,"done":2},"pending":{"count":0},"failedCount":0,"hotkey":{"display":"⌃⌥A"},"localServer":{"running":true,"busy":false}}"#.utf8))
        model.selected = "demo-215"
        #endif
    }
    private static func item(_ number: Int, _ comment: String, _ app: String, _ status: String) -> JSON {
        .object(["id": .string("demo-\(number)"), "number": .number(Double(number)), "comment": .string(comment), "status": .string(status), "element": .string("AXButton \"Open project\""), "elementPath": .string("AXWindow > AXWebArea > AXButton"), "pathname": .string("Project overview"), "url": .string("http://localhost:3000/projects"), "createdAt": .number((Date().timeIntervalSince1970 - Double(215 - number) * 30_000) * 1000), "native": .object(["app": .object(["name": .string(app), "bundleId": .string(["Finder": "com.apple.finder", "Notes": "com.apple.Notes"][app] ?? "com.apple.Safari")]), "project": .string("Website"), "mode": .string("element")])])
    }
    #if DEBUG
    static func capture(_ model: AppModel, directory: String) async {
        guard model.demo else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        guard let window = model.window else { fputs("No demo window\n", stderr); exit(1) }
        window.setContentSize(NSSize(width: 1000, height: 680)); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for appearance in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            window.appearance = NSApp.appearance
            populate(model); model.page = "all"
            await shot(window, "\(appearance)-01-library", directory)
            model.page = "open"
            await shot(window, "\(appearance)-35-open", directory)
            model.page = "all"
            window.setContentSize(Kit.windowMinSize)
            await shot(window, "\(appearance)-36-library-minimum", directory)
            window.setContentSize(NSSize(width: 1000, height: 680))
            model.selected = ""
            await shot(window, "\(appearance)-02-empty-detail", directory)
            model.searching = true; model.search = "missing"
            await shot(window, "\(appearance)-03-search-empty", directory)
            window.setContentSize(Kit.windowMinSize)
            await shot(window, "\(appearance)-37-search-minimum", directory)
            window.setContentSize(NSSize(width: 1000, height: 680))
            model.searching = false; model.search = ""; model.page = "done"; model.selected = "demo-212"
            await shot(window, "\(appearance)-04-finished", directory)
            model.page = "all"; model.selected = "demo-215"; model.state["health"] = .object(["tone": .string("error"), "title": .string("Server unreachable. Your comments are saved for retry.")])
            await shot(window, "\(appearance)-05-offline", directory)
            populate(model); model.page = "settings"
            await shot(window, "\(appearance)-06-settings", directory)
            NotificationCenter.default.post(name: .demoSettingsSection, object: "dictation")
            await shot(window, "\(appearance)-07-dictation", directory)
            model.navigate("projects")
            await shot(window, "\(appearance)-28-project-empty-detail", directory)
            model.selectedProjectID = "website"
            await shot(window, "\(appearance)-09-projects", directory)
            scrollToBottom(window.contentView)
            await shot(window, "\(appearance)-29-project-detail-bottom", directory)
            model.navigate("project:website", id: "demo-215")
            precondition(model.filtered.count == 3 && model.selectedProjectID == "website")
            await shot(window, "\(appearance)-30-project-annotations", directory)
            window.setContentSize(Kit.windowMinSize)
            await shot(window, "\(appearance)-38-filtered-minimum", directory)
            model.searching = true
            await shot(window, "\(appearance)-39-filtered-search-minimum", directory)
            model.searching = false
            window.setContentSize(NSSize(width: 1000, height: 680))
            model.navigate("projects")
            model.searching = true
            await shot(window, "\(appearance)-40-project-search", directory)
            model.searching = false
            model.selectedProjectID = "docs"
            await shot(window, "\(appearance)-31-project-zero-counts", directory)
            model.selectedProjectID = "website"
            window.setContentSize(Kit.windowMinSize)
            await shot(window, "\(appearance)-32-project-minimum", directory)
            window.setContentSize(NSSize(width: 1000, height: 680))
            let savedProjects = model.projects
            model.projects = []; model.selectedProjectID = ""
            await shot(window, "\(appearance)-33-project-empty-list", directory)
            model.projects = savedProjects; model.selectedProjectID = "website"
            let add = demoWindow(ProjectEditor(model: model, initial: newProject(), dismiss: {}), size: NSSize(width: 560, height: 640))
            await shot(add, "\(appearance)-34-project-add", directory); add.close()
            let editor = demoWindow(ProjectEditor(model: model, initial: model.projects[0], dismiss: {}), size: NSSize(width: 560, height: 640))
            await shot(editor, "\(appearance)-10-project-editor", directory)
            scrollToBottom(editor.contentView)
            await shot(editor, "\(appearance)-27-project-editor-bottom", directory); editor.close()
            let menu = demoWindow(MenuPanel(model: model), size: NSSize(width: 360, height: 560))
            await shot(menu, "\(appearance)-11-menu", directory)
            model.items = Array(model.items.prefix(2))
            model.state["health"] = .object(["tone": .string("error"), "title": .string("Server unreachable")])
            model.state["pending"]["count"] = .number(3)
            await shot(menu, "\(appearance)-26-menu-offline", directory); menu.close()
            populate(model)
            model.state["permissions"] = .object(["accessibility": .bool(false), "screenRecording": .bool(false)])
            let permissions = demoWindow(PermissionsView(model: model), size: NSSize(width: 460, height: 390))
            await shot(permissions, "\(appearance)-12-permissions", directory)
            model.state["permissions"] = .object(["accessibility": .bool(true), "screenRecording": .bool(true)])
            await shot(permissions, "\(appearance)-13-permissions-ready", directory); permissions.close()
            model.target = .object(["label": .string("Safari · Open project"), "mode": .string("element"), "dictation": .object(["autoStart": .bool(false)])]); model.comment = "Make the button label easier to read."; model.commentError = nil
            let comment = demoWindow(CommentView(model: model), size: NSSize(width: 420, height: 320))
            await shot(comment, "\(appearance)-14-comment", directory)
            model.demoDictation = "recording"
            await shot(comment, "\(appearance)-15-recording", directory)
            model.demoDictation = "idle"; model.target["mode"] = .string("window"); model.commentError = "Screen capture failed. Check Screen Recording in System Settings. Your comment can still be sent."
            await shot(comment, "\(appearance)-16-capture-error", directory)
            model.target["mode"] = .string("element")
            model.comment = ""; model.commentError = "Operator sent no text to the comment. Try again or type your comment."
            await shot(comment, "\(appearance)-16b-dictation-error", directory); comment.close()
            model.page = "all"; model.selected = ""; model.items = []; model.state["queue"] = .object(["todo": .number(0), "inProgress": .number(0), "done": .number(0)])
            await shot(window, "\(appearance)-17-empty-library", directory)
            model.page = "projects"; model.projectsError = "Could not read routes.json. Fix the file before editing projects."
            await shot(window, "\(appearance)-18-project-error", directory); model.projectsError = ""
            model.page = "settings"; NotificationCenter.default.post(name: .demoSettingsSection, object: "general")
            window.setContentSize(Kit.windowMinSize)
            await shot(window, "\(appearance)-19-minimum-size", directory)
            NotificationCenter.default.post(name: .demoSettingsSection, object: "dictation")
            await shot(window, "\(appearance)-41-dictation-minimum", directory)
            window.setContentSize(NSSize(width: 1000, height: 680))
            let raw = screenshot.split(separator: ",", maxSplits: 1)[1]
            let image = NSImage(data: Data(base64Encoded: String(raw))!)!
            let viewer = demoWindow(ScreenshotView(image: image, close: {}), size: NSSize(width: 800, height: 560))
            await shot(viewer, "\(appearance)-20-screenshot", directory); viewer.close()
            model.page = "settings"
            NotificationCenter.default.post(name: .demoSettingsSection, object: "general")
            try? await Task.sleep(for: .milliseconds(250))
            scrollToBottom(window.contentView)
            await shot(window, "\(appearance)-21-settings-bottom", directory)
            NotificationCenter.default.post(name: .demoSettingsSection, object: "dictation")
            await shot(window, "\(appearance)-21b-settings-dictation", directory)
        }
        NSApp.terminate(nil)
    }
    private static func scrollToBottom(_ view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.subviews.forEach { scrollToBottom($0) }
    }
    private static func demoWindow<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSApp.appearance
        window.contentView = NSHostingView(rootView: view); window.center(); window.orderFrontRegardless(); return window
    }
    private static func shot(_ window: NSWindow, _ name: String, _ directory: String) async {
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); try? await Task.sleep(for: .milliseconds(550))
        do {
            if ProcessInfo.processInfo.environment["ANNOTATOR_UI_OFFSCREEN"] == "1" {
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw BridgeError("Could not render the demo view")
                }
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
                return
            }
            let content = try await SCShareableContent.currentProcess
            guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw BridgeError("Demo window is not on screen") }
            let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        } catch { fputs("Capture failed: \(name): \(error)\n", stderr); exit(1) }

    }
    #endif
}
