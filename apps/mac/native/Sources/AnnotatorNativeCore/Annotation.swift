import CoreGraphics
import Foundation

/// The record this app posts to the annotation server.
/// The top-level fields match the web annotator. `native` holds the macOS details.
public struct Annotation: Codable, Sendable, Equatable {
    public var id: String
    public var timestamp: Int64
    public var comment: String
    public var element: String
    public var elementPath: String
    public var url: String
    public var pathname: String
    public var boundingBox: Box
    public var screenSize: String
    public var screenshot: String?
    /// The next four match the web annotator. Set only when the DOM element is known (DevTools).
    public var component: String?
    public var react: String?
    public var components: [DOMInfo.Frame]?
    public var appearance: DOMInfo.Appearance?
    public var native: Native

    public struct Box: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(_ rect: CGRect) {
            x = rect.minX.rounded()
            y = rect.minY.rounded()
            width = rect.width.rounded()
            height = rect.height.rounded()
        }
    }

    public struct Native: Codable, Sendable, Equatable {
        public var app: App
        public var window: Window
        public var ax: AX?
        public var webUrl: String?
        public var mode: AnnotationMode
        public var project: String?
        /// The DOM element, when the app exposes a DevTools port.
        public var dom: DOM?

        enum CodingKeys: String, CodingKey { case app, window, ax, webUrl, mode, project, dom }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(app, forKey: .app)
            try c.encode(window, forKey: .window)
            try c.encode(ax, forKey: .ax)
            try c.encode(webUrl, forKey: .webUrl)
            try c.encode(mode, forKey: .mode)
            try c.encode(project, forKey: .project)
            try c.encode(dom, forKey: .dom)
        }
    }

    public struct DOM: Codable, Sendable, Equatable {
        public var tag: String
        public var selector: String
        public var html: String
    }

    public struct App: Codable, Sendable, Equatable {
        public var name: String
        public var bundleId: String?
        public var pid: Int32

        enum CodingKeys: String, CodingKey { case name, bundleId, pid }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(bundleId, forKey: .bundleId)
            try c.encode(pid, forKey: .pid)
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var title: String?
        public var id: UInt32
        public var frame: Box

        enum CodingKeys: String, CodingKey { case title, id, frame }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(id, forKey: .id)
            try c.encode(frame, forKey: .frame)
        }
    }

    public struct AX: Codable, Sendable, Equatable {
        public var role: String?
        public var subrole: String?
        public var roleDescription: String?
        public var title: String?
        public var description: String?
        public var identifier: String?
        public var value: String?
        public var domId: String?
        public var domClasses: [String]
        public var text: String?
        public var path: [String]

        enum CodingKeys: String, CodingKey {
            case role, subrole, roleDescription, title, description, identifier, value, domId, domClasses, text, path
        }

        // Write every key, with null for missing values, so agents see a stable shape.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try c.encode(subrole, forKey: .subrole)
            try c.encode(roleDescription, forKey: .roleDescription)
            try c.encode(title, forKey: .title)
            try c.encode(description, forKey: .description)
            try c.encode(identifier, forKey: .identifier)
            try c.encode(value, forKey: .value)
            try c.encode(domId, forKey: .domId)
            try c.encode(domClasses, forKey: .domClasses)
            try c.encode(text, forKey: .text)
            try c.encode(path, forKey: .path)
        }
    }

    /// Builds the record for `target`. `screenSize` is the display size in pixels.
    public init(
        id: String = UUID().uuidString.lowercased(),
        timestamp: Date = Date(),
        comment: String,
        target: Target,
        screenSize: CGSize,
        screenshot: String?,
        project: String? = nil
    ) {
        self.id = id
        self.timestamp = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        self.comment = comment
        element = target.elementLabel
        let labels = target.pathLabels
        if let dom = target.dom, target.mode == .element {
            elementPath = dom.path.isEmpty ? dom.tag : dom.path
        } else {
            elementPath = labels.isEmpty ? target.elementLabel : labels.joined(separator: " > ")
        }
        let dom = target.mode == .element ? target.dom : nil
        component = dom?.component
        react = dom?.react
        components = dom.map(\.components).flatMap { $0.isEmpty ? nil : $0 }
        appearance = dom?.appearance
        url = target.webUrl ?? "app://\(target.app.bundleId ?? target.app.name)"
        if let title = target.window.title, !title.isEmpty, title != target.app.name {
            pathname = "\(target.app.name) — \(title)"
        } else {
            pathname = target.app.name
        }
        boundingBox = Box(target.frame)
        self.screenSize = "\(Int(screenSize.width))px, \(Int(screenSize.height))px"
        self.screenshot = screenshot
        let element = target.element
        native = Native(
            app: App(name: target.app.name, bundleId: target.app.bundleId, pid: target.app.pid),
            window: Window(title: target.window.title, id: target.window.id, frame: Box(target.window.frame)),
            ax: target.mode == .element
                ? AX(
                    role: element?.role, subrole: element?.subrole,
                    roleDescription: element?.roleDescription, title: element?.title,
                    description: element?.description, identifier: element?.identifier,
                    value: element?.value, domId: element?.domId, domClasses: element?.domClasses ?? [],
                    text: element?.text, path: labels)
                : nil,
            webUrl: target.webUrl,
            mode: target.mode,
            project: project,
            dom: dom.map { DOM(tag: $0.tag, selector: $0.selector, html: $0.html) }
        )
    }

    /// Server ids: `^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$`.
    public static func isValidID(_ id: String) -> Bool {
        guard (1...200).contains(id.count) else { return false }
        let scalars = id.unicodeScalars
        guard let first = scalars.first, Annotation.idHead.contains(first) else { return false }
        return scalars.dropFirst().allSatisfy { Annotation.idTail.contains($0) }
    }

    private static let idHead = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let idTail = idHead.union(CharacterSet(charactersIn: "_-"))

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Annotation {
        try JSONDecoder().decode(Annotation.self, from: data)
    }
}
