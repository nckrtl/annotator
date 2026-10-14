import CoreGraphics

/// The elements of menus and flyouts as they were when annotate mode started.
/// They close once the comment panel takes focus; their record keeps them selectable on the frozen screen.
public struct FrozenElements: Sendable, Equatable {
    /// The recorded windows, in global top-left points.
    public var windows: [CGRect]
    public var targets: [Target]

    public init(windows: [CGRect] = [], targets: [Target] = []) {
        self.windows = windows
        self.targets = targets
    }

    /// Whether `point` falls in a recorded window. Then the record answers, not live accessibility.
    public func covers(_ point: CGPoint) -> Bool {
        windows.contains { $0.contains(point) }
    }

    /// The smallest recorded element at `point`. Menus hide unnamed items under the visible ones,
    /// so a named element wins over an unnamed one of the same size.
    public func target(at point: CGPoint) -> Target? {
        targets.filter { $0.frame.contains(point) }.min {
            let (a, b) = (area($0.frame), area($1.frame))
            return a != b ? a < b : ($0.element?.name != nil && $1.element?.name == nil)
        }
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}

extension Geometry {
    /// `rect` in display-relative points as a pixel rectangle in an image of the whole display.
    /// Clipped to the image, so rounding never reads past its edge.
    public static func pixelRect(of rect: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        let pixels = CGRect(
            x: (rect.minX * scale).rounded(.down), y: (rect.minY * scale).rounded(.down),
            width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let clipped = pixels.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }
}
