import AnnotatorNativeCore
import AppKit
import ApplicationServices

/// The only place that touches `AXUIElement`. All reads run on one background queue,
/// because accessibility calls block while the target app is busy.
final class AXReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nckrtl.annotator.ax", qos: .userInteractive)
    /// Electron apps that already got `AXManualAccessibility`. Touched only on `queue`.
    private var manualAccessibility = Set<pid_t>()

    init() {
        // Applies to every element: a hung app costs at most 0.25 s per call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// The element under `point` (global top-left points), or the window when no element has a usable frame.
    /// Nil when no app window is under the point.
    /// `text` walks children for a name. Hover leaves it off so a slow tree cannot stall the highlight.
    func target(at point: CGPoint, text: Bool = true) async -> Target? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readTarget(at: point, text: text)) }
        }
    }

    /// Every element in the open menus and flyouts, recorded before they close.
    func frozenElements() async -> FrozenElements {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readFrozenElements()) }
        }
    }

    /// The app window under `point`, for region annotations.
    func window(at point: CGPoint) async -> (AppInfo, WindowInfo)? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.topWindow(at: point).map { ($0.app, $0.window) })
            }
        }
    }

    // MARK: - Windows

    private static let menuLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow)),
        Int(CGWindowLevelForKey(.popUpMenuWindow)),
    ]

    private struct FoundWindow {
        var app: AppInfo
        var window: WindowInfo
        var bundleURL: URL?
    }

    /// The topmost window at `point`. Skips the helper's overlay and system layers.
    /// App windows (below 20), the menu bar (24), status items (25) and open menus (101) count.
    private func topWindow(at point: CGPoint) -> FoundWindow? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                (0..<20).contains(layer) || AXReader.menuLayers.contains(layer),
                let found = window(from: info), found.window.frame.contains(point)
            else { continue }
            return found
        }
        return nil
    }

    /// A window of another app that shows content. Nil for ours, invisible ones and the Window Server's.
    private func window(from info: [String: Any]) -> FoundWindow? {
        guard
            let pid = info[kCGWindowOwnerPID as String] as? pid_t, !ourPids.contains(pid),
            (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
            let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsInfo),
            let number = info[kCGWindowNumber as String] as? UInt32
        else { return nil }
        let owner = info[kCGWindowOwnerName as String] as? String
        if owner == "Window Server" { return nil }
        let bundle = AXReader.bundle(of: pid)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? owner ?? "Unknown"
        let app = AppInfo(name: name, bundleId: bundle?.bundleIdentifier, pid: pid)
        let title = info[kCGWindowName as String] as? String
        return FoundWindow(
            app: app, window: WindowInfo(title: title, id: number, frame: bounds), bundleURL: bundle?.bundleURL)
    }

    /// The windows on screen, front to back. The focused app's focused window and open menus and flyouts
    /// get their elements mapped, so they stay selectable once the screen is frozen. A window whose map
    /// does not finish within the budget stays on live hit testing; it is never half mapped.
    private func readFrozenElements() -> FrozenElements {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return FrozenElements() }
        let focusedApp: AXUIElement? = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)
        var focusedPid: pid_t = 0
        if let focusedApp { AXUIElementGetPid(focusedApp, &focusedPid) }
        let focusedWindow = focusedApp.flatMap { (attribute($0, kAXFocusedWindowAttribute) as AXUIElement?) }
        let focusedFrame = focusedWindow.flatMap { frame(of: $0) }
        let menuLayers = [Int(CGWindowLevelForKey(.statusWindow)), Int(CGWindowLevelForKey(.popUpMenuWindow))]
        let deadline = Date().addingTimeInterval(1.5)

        var frozen = FrozenElements()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                (0..<20).contains(layer) || AXReader.menuLayers.contains(layer),
                let found = window(from: info)
            else { continue }
            var window = FrozenWindow(id: found.window.id, frame: found.window.frame)
            let isMenu = menuLayers.contains(layer) && found.window.frame.height > 40
            let isFocused = found.app.pid == focusedPid && focusedFrame.map { Self.same($0, found.window.frame) } == true
            if isMenu || isFocused, Date() < deadline,
                let root = isFocused ? focusedWindow : rootElement(of: found),
                let mapped = map(root, in: found, until: deadline)
            {
                window.target = Target(mode: .window, app: found.app, window: found.window, frame: found.window.frame)
                window.elements = mapped
                window.menu = isMenu
            }
            frozen.windows.append(window)
        }
        return frozen
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The element that holds a menu or flyout window: its AXWindow when the app lists one with that frame,
    /// else the AXMenu or AXWindow above the element at its center.
    private func rootElement(of found: FoundWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(found.app.pid)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        if let match = windows.first(where: { frame(of: $0).map { Self.same($0, found.window.frame) } == true }) {
            return match
        }
        var hit: AXUIElement?
        let frame = found.window.frame
        guard AXUIElementCopyElementAtPosition(app, Float(frame.midX), Float(frame.midY), &hit) == .success,
            var current = hit
        else { return nil }
        for _ in 0..<64 {
            let role: String? = attribute(current, kAXRoleAttribute)
            if role == kAXMenuRole || role == kAXWindowRole { return current }
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute),
                (attribute(parent, kAXRoleAttribute) as String?) != kAXApplicationRole
            else { return current }
            current = parent
        }
        return current
    }

    /// Every element under `root` that shows inside the window, breadth first, with its path from `root`.
    /// Nil when the tree does not finish by `deadline` or has more than 5,000 elements.
    private func map(_ root: AXUIElement, in found: FoundWindow, until deadline: Date) -> [Target]? {
        var targets: [Target] = []
        var queue: [(AXUIElement, [AXElementInfo])] = [(root, [])]
        var index = 0
        while index < queue.count {
            guard index < 5_000, Date() < deadline else { return nil }
            let (element, parents) = queue[index]
            index += 1
            let node = read(element)
            let path = parents + [node.info]
            if let frame = node.frame?.intersection(found.window.frame), Geometry.isUsable(frame) {
                targets.append(Target(
                    mode: .element, app: found.app, window: found.window, frame: frame, element: node.info, path: path))
            }
            queue.append(contentsOf: node.children.map { ($0, path) })
        }
        return targets
    }

    private static let mappedAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute, kAXHelpAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]

    /// One element's details, frame and children in a single accessibility call.
    private func read(_ element: AXUIElement) -> (info: AXElementInfo, frame: CGRect?, children: [AXUIElement]) {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.mappedAttributes as CFArray, [], &raw) == .success,
            let values = raw as? [AnyObject], values.count == 11
        else { return (info(element), frame(of: element), attribute(element, kAXChildrenAttribute) ?? []) }
        func string(_ i: Int) -> String? {
            if let text = values[i] as? String { return text.isEmpty ? nil : text }
            if let number = values[i] as? NSNumber, CFGetTypeID(number) != AXValueGetTypeID() { return number.stringValue }
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        var frame: CGRect?
        if CFGetTypeID(values[8]) == AXValueGetTypeID(), CFGetTypeID(values[9]) == AXValueGetTypeID(),
            AXValueGetValue(values[8] as! AXValue, .cgPoint, &position),
            AXValueGetValue(values[9] as! AXValue, .cgSize, &size)
        {
            frame = CGRect(origin: position, size: size)
        }
        let children = (values[10] as? [AnyObject] ?? []).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        let info = AXElementInfo(
            role: values[0] as? String, subrole: values[1] as? String, roleDescription: values[2] as? String,
            title: values[3] as? String, description: values[4] as? String, identifier: values[5] as? String,
            value: string(6), help: values[7] as? String)
        return (info, frame, children)
    }

    /// The app bundle that contains the process's executable. Read from the executable path, because
    /// `NSRunningApplication` can name the app that launched a process instead (a dev build started from a terminal).
    /// Helpers inside another app's `Frameworks` folder resolve to that app.
    static func bundle(of pid: pid_t) -> Bundle? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        var url = URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self))
        // The innermost .app, unless it is a helper inside another app's Frameworks folder.
        while url.path != "/" {
            if url.pathExtension == "app", url.deletingLastPathComponent().lastPathComponent != "Frameworks" {
                return Bundle(url: url)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Elements

    private func readTarget(at point: CGPoint, text: Bool) -> Target? {
        guard let found = topWindow(at: point) else { return nil }
        let appElement = AXUIElementCreateApplication(found.app.pid)
        enableElectronAccessibility(appElement, pid: found.app.pid, bundleURL: found.bundleURL)

        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit)

        let fallback = Target(mode: .window, app: found.app, window: found.window, frame: found.window.frame)
        guard status == .success, let hit else { return fallback }
        return target(for: hit, in: found, text: text) ?? fallback
    }

    /// The target for `hit`, with its path from the window down. Nil when it has no usable frame.
    private func target(for hit: AXUIElement, in found: FoundWindow, text: Bool) -> Target? {
        var found = found

        // Walk up to the window: the path runs from the window down to the element.
        var chain: [AXUIElement] = [hit]
        var current = hit
        while chain.count < 64, let parent: AXUIElement = attribute(current, kAXParentAttribute) {
            let role: String? = attribute(parent, kAXRoleAttribute)
            if role == kAXApplicationRole { break }
            chain.append(parent)
            if role == kAXWindowRole { break }
            current = parent
        }
        chain.reverse()
        var path = chain.map(info)
        // A plain web <div> has no name. Describe it by the text inside it. Hover skips this walk.
        if text, var element = path.last, element.name == nil {
            element.text = innerText(of: hit).map { AXElementInfo.truncate($0, to: 120) }
            path[path.count - 1] = element
        }

        if let windowElement = chain.first, path.first?.role == kAXWindowRole,
            let title: String = attribute(windowElement, kAXTitleAttribute), !title.isEmpty
        {
            found.window.title = title
        }

        var webUrl: String?
        var webAreaFrame: CGRect?
        if let webArea = chain.last(where: { (attribute($0, kAXRoleAttribute) as String?) == "AXWebArea" }) {
            webAreaFrame = frame(of: webArea)
            if let url: URL = attribute(webArea, "AXURL") {
                webUrl = url.absoluteString
            } else if let document: String = attribute(webArea, "AXDocument") {
                webUrl = document
            }
        }

        // Large scroll content can extend past the window; clip to what is visible.
        guard let frame = frame(of: hit)?.intersection(found.window.frame), Geometry.isUsable(frame) else {
            return nil
        }
        return Target(
            mode: .element, app: found.app, window: found.window, frame: frame,
            element: path.last, path: path, webUrl: webUrl, webArea: webAreaFrame)
    }

    /// Electron apps expose an empty tree until a client asks for it. Ask once per process.
    /// Do not set `AXEnhancedUserInterface`: it breaks window animations in some apps.
    private func enableElectronAccessibility(_ app: AXUIElement, pid: pid_t, bundleURL: URL?) {
        guard !manualAccessibility.contains(pid), let bundleURL else { return }
        let framework = bundleURL.appending(path: "Contents/Frameworks/Electron Framework.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else { return }
        manualAccessibility.insert(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func info(_ element: AXUIElement) -> AXElementInfo {
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        // Do not copy the value out of a secure field. The attribute often holds the secret.
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        return AXElementInfo(
            role: role,
            subrole: subrole,
            roleDescription: attribute(element, kAXRoleDescriptionAttribute),
            title: attribute(element, kAXTitleAttribute),
            description: attribute(element, kAXDescriptionAttribute),
            identifier: attribute(element, kAXIdentifierAttribute),
            value: secure ? nil : stringValue(element),
            help: attribute(element, kAXHelpAttribute),
            domId: attribute(element, "AXDOMIdentifier"),
            domClasses: attribute(element, "AXDOMClassList") ?? [])
    }

    /// The first few pieces of text below `element`, breadth first. Bounded, because big trees are slow.
    private func innerText(of element: AXUIElement) -> String? {
        var queue = [element]
        var pieces: [String] = []
        var visited = 0
        while !queue.isEmpty, visited < 60, pieces.count < 4 {
            let current = queue.removeFirst()
            visited += 1
            let role: String? = attribute(current, kAXRoleAttribute)
            if role == kAXStaticTextRole, let text = stringValue(current)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                pieces.append(text)
                continue
            }
            let children: [AXUIElement] = attribute(current, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children.prefix(20))
        }
        let text = pieces.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? nil : text
    }

    /// `kAXValueAttribute` can be a string, a number or something else entirely.
    private func stringValue(_ element: AXUIElement) -> String? {
        guard let raw = rawAttribute(element, kAXValueAttribute) else { return nil }
        if let string = raw as? String { return string.isEmpty ? nil : string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let rawPosition = axValue(element, kAXPositionAttribute),
            AXValueGetValue(rawPosition, .cgPoint, &position),
            let rawSize = axValue(element, kAXSizeAttribute),
            AXValueGetValue(rawSize, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let raw = rawAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // The type check above makes the cast safe.
        return (raw as! AXValue)
    }

    private func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        guard let raw = rawAttribute(element, name) else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! T)
        }
        return raw as? T
    }
}
