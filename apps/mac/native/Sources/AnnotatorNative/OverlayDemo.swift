#if DEBUG
import AppKit
import ScreenCaptureKit
import AnnotatorNativeCore

/// Captures the production overlay renderer over a local fixture. No hit tests or desktop access.
@MainActor enum OverlayDemo {
    static func capture(directory: String) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let controller = OverlayController(reader: AXReader())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let background = Background(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
        let overlay = OverlayView(controller: controller); overlay.frame = background.bounds
        background.addSubview(overlay); window.contentView = background
        window.center(); window.orderFrontRegardless()
        for mode in ["light", "dark"] {
            window.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            for (index, selection) in [AnnotationMode.element, .window, .region].enumerated() {
                let local = selection == .window ? CGRect(x: 28, y: 28, width: 704, height: 330) : CGRect(x: 54, y: 144, width: 280, height: 90)
                let global = local.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
                let frame = Geometry.topLeft(fromAppKit: global, mainScreenHeight: NSScreen.mainHeight)
                let target = Target(mode: selection, app: AppInfo(name: "Preview", bundleId: "com.example.preview", pid: getpid()), window: WindowInfo(title: "Project overview", id: UInt32(window.windowNumber), frame: frame), frame: frame,
                    element: selection == .element ? AXElementInfo(role: "AXButton", title: "Open project") : nil)
                controller.showDemo(target); background.needsDisplay = true; overlay.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(400))
                do {
                    let content = try await SCShareableContent.currentProcess
                    guard let own = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) }) else { fputs("Overlay demo window is not on screen\n", stderr); exit(1) }
                    let config = SCStreamConfiguration(); config.width = 1520; config.height = 840; config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let path = directory + "/\(mode)-\(23 + index)-overlay-\(selection.rawValue).png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                } catch { fputs("Overlay capture failed: \(error)\n", stderr); exit(1) }
            }
        }
        window.close()
    }
    final class Background: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            NSColor.textBackgroundColor.setFill(); NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 704, height: 330), xRadius: 14, yRadius: 14).fill()
            ("Project overview" as NSString).draw(at: NSPoint(x: 54, y: 294), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.labelColor])
            ("A local fixture for the annotation overlay" as NSString).draw(at: NSPoint(x: 54, y: 262), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])
            ("Open project" as NSString).draw(at: NSPoint(x: 78, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.labelColor])
        }
    }
}
#endif
