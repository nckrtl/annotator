#if DEBUG
import AppKit
import SwiftUI
import DesignKit
import ScreenCaptureKit

/// Checks intrinsic menu sizing and its window actions without touching user data.
@MainActor enum MenuCheck {
    static func run(_ model: AppModel, directory: String) async {
        guard model.demo else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try await Task.sleep(for: .seconds(1))

            for appearance in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                Demo.populate(model)
                try await statusItemShots(model, appearance: appearance, directory: directory)
                let host = NSHostingView(rootView: MenuPanel(model: model).kitAppearance())
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.appearance = NSApp.appearance
                window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
                try await settle()
                window.setContentSize(host.fittingSize)
                try await settle()
                precondition(window.frame.width == 360 && window.frame.height > 200 && window.frame.height <= 620, "Menu must have a usable intrinsic size")
                print("PASS \(appearance) intrinsic menu: \(window.frame.size)")
                await shot(window, name: "\(appearance)-menu", directory: directory)
                for (label, page) in [("Settings", "settings"), ("Projects", "projects"), ("Open library", "all")] {
                    model.window?.close()
                    window.makeKeyAndOrderFront(nil)
                    model.navigate(page)
                    try await settle()
                    precondition(model.page == page && model.window?.isVisible == true, "Menu must reopen the main window")
                    model.window?.appearance = NSApp.appearance
                    await shot(model.window!, name: "\(appearance)-\(page)", directory: directory)
                    print("PASS \(appearance) \(label) reopens main window")
                }
                for item in model.items {
                    model.navigate("all", id: item["id"].string)
                    try await settle()
                    precondition(model.selected == item["id"].string && model.window?.isVisible == true)
                    await shot(model.window!, name: "\(appearance)-recent-\(item["number"].int)", directory: directory)
                }
                model.panels?.permissions()
                try await settle()
                if let permissions = model.panels?.permissionWindow {
                    permissions.appearance = NSApp.appearance
                    await shot(permissions, name: "\(appearance)-permissions", directory: directory)
                    permissions.close()
                }
                model.items = []
                window.makeKeyAndOrderFront(nil)
                try await settle(); window.setContentSize(host.fittingSize); try await settle()
                await shot(window, name: "\(appearance)-menu-empty", directory: directory)
                Demo.populate(model)
                model.state["health"] = .object(["tone": .string("error"), "title": .string("Server unreachable")])
                model.state["pending"]["count"] = .number(3)
                model.state["failedCount"] = .number(2)
                try await settle(); window.setContentSize(host.fittingSize); try await settle()
                await shot(window, name: "\(appearance)-menu-offline", directory: directory)
                precondition(window.frame.height <= 620)
                scrollToBottom(host)
                try await settle()
                await shot(window, name: "\(appearance)-menu-offline-bottom", directory: directory)
                window.close()
            }
            print("PASS menu checks")
        } catch { fatalError("Menu check: \(error)") }
        NSApp.terminate(nil)
    }
    /// The system hosts status items outside the app's capturable window list. Capture the
    /// actual status-item view, including its queue count, at 2x in each native appearance.
    static func statusItemShots(_ model: AppModel, appearance: String, directory: String) async throws {
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)) == "NSStatusBarWindow" }),
              let view = window.contentView else { throw NSError(domain: "MenuCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "No status-item view"]) }
        window.appearance = NSApp.appearance
        for active in [false, true] {
            model.state["annotating"] = .bool(active)
            try await settle()
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "MenuCheck", code: 2) }
            bitmap.size = bounds.size
            view.cacheDisplay(in: bounds, to: bitmap)
            let name = "\(appearance)-menu-bar-\(active ? "annotating" : "idle").png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/" + name))
            print("PASS \(appearance) menu-bar \(active ? "annotating" : "idle") view captured with queue count")
        }
        model.state["annotating"] = .bool(false)
    }
    static func scrollToBottom(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.subviews.forEach(scrollToBottom)
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }
    static func shot(_ window: NSWindow, name: String, directory: String) async {
        guard let number = CGWindowID(exactly: window.windowNumber), number > 0 else { fatalError("Window is not visible: \(name)") }
        do {
            try await settle()
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == number }) else { fatalError("Window missing: \(name)") }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        } catch { fatalError("Capture \(name): \(error)") }
    }
}
#endif
