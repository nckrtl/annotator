import CoreGraphics

/// One window on screen when annotate mode started, front to back.
public struct FrozenWindow: Sendable, Equatable {
    public var id: UInt32
    /// Global top-left points.
    public var frame: CGRect
    /// The window itself, when its elements were mapped. Nil keeps hover there live.
    public var target: Target?
    public var elements: [Target]
    /// A menu or flyout. It closes once the comment panel takes focus, so only the map can answer for it.
    public var menu: Bool

    public init(id: UInt32, frame: CGRect, target: Target? = nil, elements: [Target] = [], menu: Bool = false) {
        self.id = id
        self.frame = frame
        self.target = target
        self.elements = elements
        self.menu = menu
    }
}

/// The screen's windows and the mapped elements of the focused window and of open menus and flyouts,
/// as they were when annotate mode started. Menus close once the comment panel takes focus;
/// the map keeps them selectable on the frozen screen.
public struct FrozenElements: Sendable, Equatable {
    public enum Lookup: Equatable {
        case live
        case mapped(Target, menu: Bool)
    }

    /// Front to back.
    public var windows: [FrozenWindow]

    public init(windows: [FrozenWindow] = []) {
        self.windows = windows
    }

    /// The frontmost window at `point` decides. In a mapped window, the smallest element at `point`
    /// wins, and the window itself without one. Menus hide unnamed items under the visible ones,
    /// so a named element wins over an unnamed one of the same size.
    public func lookup(_ point: CGPoint) -> Lookup {
        guard let window = windows.first(where: { $0.frame.contains(point) }), let target = window.target
        else { return .live }
        let element = window.elements.filter { $0.frame.contains(point) }.min {
            let (a, b) = (area($0.frame), area($1.frame))
            return a != b ? a < b : ($0.element?.name != nil && $1.element?.name == nil)
        }
        return .mapped(element ?? target, menu: window.menu)
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
