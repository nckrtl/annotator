import AnnotatorNativeCore
import AppKit
import ApplicationServices

/// The only place that touches `AXUIElement`. All reads run on one background queue,
/// because accessibility calls block while the target app is busy.
final class AXReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nckrtl.annotator.ax", qos: .userInteractive)
    /// Electron apps that already got `AXManualAccessibility`. Touched only on `queue`.
    private var manualAccessibility: [pid_t: Date] = [:]

    init() {
        // Applies to every element: a hung app costs at most 0.25 s per call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// The element under `point` (global top-left points), or the window when no element has a usable frame.
    /// Nil when no app window is under the point.
    /// `text` walks children for a name. Hover leaves it off so a slow tree cannot stall the highlight.
    func target(at point: CGPoint, text: Bool = true) async -> Target? {
        await Self.waitForWebArea(text: text) {
            await withCheckedContinuation { continuation in
                self.queue.async {
                    let target = self.readTarget(at: point, text: text)
                    let warming = target.flatMap { self.manualAccessibility[$0.app.pid] }
                        .map { Date().timeIntervalSince($0) < 1 } ?? false
                    continuation.resume(returning: (target, warming))
                }
            }
        }
    }

    static func waitForWebArea(text: Bool, read: @Sendable () async -> (Target?, Bool)) async -> Target? {
        // Electron builds its tree asynchronously. Only selection waits, and only
        // during the first second after a successful accessibility request.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(350))
        for attempt in 0..<8 {
            let (target, warming) = await read()
            if !text || !warming || target?.webArea != nil || attempt == 7 || ContinuousClock.now >= deadline {
                return target
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return target }
        }
        return nil
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

    private struct FoundWindow {
        var app: AppInfo
        var window: WindowInfo
        var bundleURL: URL?
    }

    /// The topmost window at `point`. Skips the helper's and Annotator's windows and system layers
    /// (Dock at 20, menu bar at 24, status items at 25 and above).
    private func topWindow(at point: CGPoint) -> FoundWindow? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for info in list {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, !ourPids.contains(pid),
                let layer = info[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo), bounds.contains(point),
                let number = info[kCGWindowNumber as String] as? UInt32
            else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String
            if owner == "Window Server" { continue }
            let bundle = AXReader.bundle(of: pid)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? owner ?? "Unknown"
            let app = AppInfo(name: name, bundleId: bundle?.bundleIdentifier, pid: pid)
            let title = info[kCGWindowName as String] as? String
            return FoundWindow(
                app: app, window: WindowInfo(title: title, id: number, frame: bounds), bundleURL: bundle?.bundleURL)
        }
        return nil
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
        guard var found = topWindow(at: point) else { return nil }
        let appElement = AXUIElementCreateApplication(found.app.pid)
        enableElectronAccessibility(appElement, pid: found.app.pid, bundleURL: found.bundleURL)

        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit)

        let fallback = Target(mode: .window, app: found.app, window: found.window, frame: found.window.frame)
        guard status == .success, let hit else { return fallback }

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
            return Target(mode: .window, app: found.app, window: found.window, frame: found.window.frame)
        }
        return Target(
            mode: .element, app: found.app, window: found.window, frame: frame,
            element: path.last, path: path, webUrl: webUrl, webArea: webAreaFrame)
    }

    /// Electron apps expose an empty tree until a client asks for it. Ask once per process.
    /// Do not set `AXEnhancedUserInterface`: it breaks window animations in some apps.
    private func enableElectronAccessibility(_ app: AXUIElement, pid: pid_t, bundleURL: URL?) {
        guard manualAccessibility[pid] == nil, let bundleURL else { return }
        let framework = bundleURL.appending(path: "Contents/Frameworks/Electron Framework.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else { return }
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            manualAccessibility[pid] = Date()
        }
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
