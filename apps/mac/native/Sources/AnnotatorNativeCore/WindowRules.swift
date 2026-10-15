import CoreGraphics

public enum WindowRules {
    /// Screenshot leaves a display-sized selection canvas at menu-bar level. It has no
    /// app elements and must not obscure the windows below it in either hit-test path.
    /// Keep its smaller toolbar and floating previews selectable.
    public static func isScreenshotCanvas(bundleID: String?, frame: CGRect, displays: [CGRect]) -> Bool {
        guard bundleID == "com.apple.screencaptureui" else { return false }
        return displays.contains { Geometry.isUsable($0) && frame.contains($0.insetBy(dx: 1, dy: 1)) }
    }
}
