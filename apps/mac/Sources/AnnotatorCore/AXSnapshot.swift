import CoreGraphics

/// The accessibility attributes of one element, read once by `AXReader`.
public struct AXElementInfo: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var description: String?
    public var identifier: String?
    public var value: String?
    public var help: String?
    /// The HTML `id`, for web content.
    public var domId: String?
    /// The HTML classes, for web content.
    public var domClasses: [String]
    /// Visible text inside an element that has no name of its own, such as a `<div>`.
    public var text: String?

    public init(
        role: String? = nil, subrole: String? = nil, roleDescription: String? = nil,
        title: String? = nil, description: String? = nil, identifier: String? = nil,
        value: String? = nil, help: String? = nil,
        domId: String? = nil, domClasses: [String] = [], text: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.description = description
        self.identifier = identifier
        self.value = value.map { AXElementInfo.truncate($0) }
        self.help = help
        self.domId = domId.flatMap { $0.isEmpty ? nil : $0 }
        self.domClasses = domClasses
        self.text = text.map { AXElementInfo.truncate($0, to: 120) }
    }

    public static let maxValueLength = 200

    public static func truncate(_ text: String, to limit: Int = maxValueLength) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// The name shown in labels and paths: title, description, value, then inner text.
    public var name: String? {
        [title, description, value, text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// `AXStaticText "Inbox"`, or just the role when the element has no name.
    /// Web elements with an HTML id read `AXGroup#settings "Settings"`.
    public var label: String {
        let role = (role ?? "AXUnknown") + (domId.map { "#\($0)" } ?? "")
        guard let name else { return role }
        let short = AXElementInfo.truncate(name.replacingOccurrences(of: "\n", with: " "), to: 60)
        return "\(role) \"\(short.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

public struct AppInfo: Sendable, Equatable {
    public var name: String
    public var bundleId: String?
    public var pid: Int32

    public init(name: String, bundleId: String?, pid: Int32) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
    }
}

public struct WindowInfo: Sendable, Equatable {
    public var title: String?
    public var id: UInt32
    /// Global top-left points.
    public var frame: CGRect

    public init(title: String?, id: UInt32, frame: CGRect) {
        self.title = title
        self.id = id
        self.frame = frame
    }
}

public enum AnnotationMode: String, Sendable, Codable {
    case element, window, region
}

/// What the user pointed at. `frame` is in global top-left points.
public struct Target: Sendable, Equatable {
    public var mode: AnnotationMode
    public var app: AppInfo
    public var window: WindowInfo
    public var frame: CGRect
    /// The element itself; nil for window and region targets.
    public var element: AXElementInfo?
    /// From the window down to the element.
    public var path: [AXElementInfo]
    /// `AXURL` of the enclosing web area, for web content.
    public var webUrl: String?
    /// The enclosing web area on screen, in global top-left points: the page's viewport.
    public var webArea: CGRect?
    /// The DOM element, when the app exposes a DevTools port.
    public var dom: DOMInfo?

    public init(
        mode: AnnotationMode, app: AppInfo, window: WindowInfo, frame: CGRect,
        element: AXElementInfo? = nil, path: [AXElementInfo] = [], webUrl: String? = nil, webArea: CGRect? = nil
    ) {
        self.mode = mode
        self.app = app
        self.window = window
        self.frame = frame
        self.element = element
        self.path = path
        self.webUrl = webUrl
        self.webArea = webArea
    }

    public var pathLabels: [String] { path.map(\.label) }

    public var elementLabel: String {
        if mode == .element, let dom { return dom.name }
        return switch mode {
        case .element: element?.label ?? "AXUnknown"
        case .window: "AXWindow" + (window.title.map { " \"\($0)\"" } ?? "")
        case .region: "Region"
        }
    }

    /// The overlay label: app name, then role and title.
    public var overlayLabel: String {
        switch mode {
        case .element where dom?.react != nil: "\(app.name) · \(elementLabel) · \(dom?.react ?? "")"
        case .element: "\(app.name) · \(elementLabel)"
        case .window: "\(app.name) · Window (no element found)"
        case .region: "\(app.name) · Region"
        }
    }
}
