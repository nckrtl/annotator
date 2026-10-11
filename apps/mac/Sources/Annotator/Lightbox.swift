import AppKit

/// Shows one image at real size over a blurred, dimmed backdrop on the current display.
/// A click anywhere or Esc closes it.
@MainActor
enum Lightbox {
    private static var panel: LightboxPanel?

    static func show(_ image: NSImage) {
        close()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let panel = LightboxPanel(screen: screen, image: image)
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class LightboxPanel: NSPanel {
    init(screen: NSScreen, image: NSImage) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)

        let blur = NSVisualEffectView(frame: CGRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let dim = NSView(frame: blur.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.autoresizingMask = [.width, .height]
        blur.addSubview(dim)

        // Captures are made at the display's pixel density, so pixels ÷ scale is the size it had on screen.
        let pixels = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            ?? image.size
        let natural = CGSize(width: pixels.width / screen.backingScaleFactor, height: pixels.height / screen.backingScaleFactor)
        let room = screen.frame.size.applying(.init(scaleX: 0.92, y: 0.92))
        let scale = min(1, room.width / natural.width, room.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)

        let view = NSImageView(frame: CGRect(
            x: (screen.frame.width - size.width) / 2, y: (screen.frame.height - size.height) / 2,
            width: size.width, height: size.height))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        blur.addSubview(view)

        contentView = blur
    }

    override var canBecomeKey: Bool { true }

    override func mouseUp(with event: NSEvent) { Lightbox.close() }
    override func cancelOperation(_ sender: Any?) { Lightbox.close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { Lightbox.close() } else { super.keyDown(with: event) }
    }
}
