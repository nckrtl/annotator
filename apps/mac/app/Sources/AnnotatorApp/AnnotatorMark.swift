import SwiftUI
import AppKit

/// Annotator's supplied logo in the current foreground style.
struct AnnotatorMark: View {
    var size: CGFloat = 34

    var body: some View {
        Image("brand-annotator-sidebar", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Annotator")
    }
}

/// The menu bar template image: 16 pt artwork centred in an 18 pt canvas, in idle and annotating
/// states. MenuBarExtra uses the image's native size, not a resizable view's frame.
@MainActor
enum AnnotatorMenuBarIcon {
    static func image(annotating: Bool, size: CGFloat = 18) -> NSImage? {
        let name = annotating ? "brand-annotator-menu-active" : "brand-annotator-menu-idle"
        guard let artwork = Bundle.module.image(forResource: name),
              artwork.size.width > 0, artwork.size.height > 0 else { return nil }
        let extent = size * (16.0 / 18.0)
        let scale = extent / max(artwork.size.width, artwork.size.height)
        let dimensions = NSSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
        let rect = NSRect(x: (size - dimensions.width) / 2, y: (size - dimensions.height) / 2,
                          width: dimensions.width, height: dimensions.height)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}
