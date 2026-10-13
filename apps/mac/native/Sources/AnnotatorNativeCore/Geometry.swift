import CoreGraphics

/// Converts between the two coordinate systems on macOS.
///
/// AppKit uses global points with a bottom-left origin at the main screen.
/// Accessibility, CoreGraphics windows and ScreenCaptureKit use global points
/// with a top-left origin at the main screen. Both share the x axis.
/// `mainScreenHeight` is the height of the screen whose AppKit frame starts at (0, 0).
public enum Geometry {
    public static func topLeft(fromAppKit point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }

    public static func topLeft(fromAppKit rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The conversion is its own inverse.
    public static func appKit(fromTopLeft rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        topLeft(fromAppKit: rect, mainScreenHeight: mainScreenHeight)
    }

    /// The capture rectangle: `rect` plus `margin` on each side, clipped to the display.
    /// Both rectangles are in global top-left points. The result is relative to the display.
    public static func captureRect(for rect: CGRect, margin: CGFloat, display: CGRect) -> CGRect? {
        let clipped = rect.insetBy(dx: -margin, dy: -margin).intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// Size in pixels of a rectangle in points on a display with `scale` pixels per point.
    public static func pixelSize(of rect: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    }

    /// Whether a frame is big enough to highlight.
    public static func isUsable(_ rect: CGRect?) -> Bool {
        guard let rect, !rect.isNull, !rect.isInfinite else { return false }
        return rect.width >= 2 && rect.height >= 2
    }
}
