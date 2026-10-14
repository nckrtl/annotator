import AppKit
import DesignKit

/// A vector template for the native status item. AppKit supplies the menu bar's ink color.
@MainActor enum StatusIcon {
    private static let idle = make(annotating: false)
    private static let active = make(annotating: true)

    static func image(annotating: Bool) -> NSImage { annotating ? active : idle }

    private static func make(annotating: Bool) -> NSImage {
        let pencil = NSImage(systemSymbolName: KitIcon.edit.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))!
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            pencil.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16))
            // The annotation dot fills while screen selection is active.
            NSColor.black.set()
            let dot = NSBezierPath(ovalIn: NSRect(x: 13.5, y: 1.5, width: 3, height: 3))
            dot.lineWidth = 1
            if annotating { dot.fill() } else { dot.stroke() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Annotator"
        return image
    }
}
