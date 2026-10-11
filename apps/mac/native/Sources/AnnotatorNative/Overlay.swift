import AnnotatorNativeCore
import AppKit

extension NSScreen {
    /// Height of the screen at AppKit (0, 0). All conversions go through `Geometry` with it.
    @MainActor static var mainHeight: CGFloat { screens.first?.frame.height ?? 0 }

    /// The frame in global top-left points.
    @MainActor var topLeftFrame: CGRect { Geometry.topLeft(fromAppKit: frame, mainScreenHeight: NSScreen.mainHeight) }
}

/// The annotate-mode overlay: one transparent panel per screen that takes all mouse events,
/// draws the highlight, and reports a clicked element or a dragged region.
@MainActor
final class OverlayController {
    enum State {
        case hovering(Target?)
        case dragging(start: CGPoint, end: CGPoint)
        /// A target was picked; the comment panel is open.
        case frozen(Target)
    }

    private let reader: AXReader
    private let devTools = DevTools()
    private var panels: [OverlayPanel] = []
    private(set) var state: State = .hovering(nil)
    var onSelect: ((Target) -> Void)?
    /// A click on the overlay while the comment panel is open: finish that comment, then move here.
    var onClickWhileFrozen: ((CGPoint) -> Void)?
    /// Esc while an overlay panel is key. A backup for Annotator's global Esc hotkey.
    var onEscape: (() -> Void)?

    private var hitTestRunning = false
    private var queuedPoint: CGPoint?
    private var lastHitTest = Date.distantPast
    private let hitTestInterval: TimeInterval = 1.0 / 30

    var isVisible: Bool { !panels.isEmpty }

    init(reader: AXReader) {
        self.reader = reader
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.hide()
                self.show()
            }
        }
    }

    func show() {
        guard panels.isEmpty else { return }
        state = .hovering(nil)
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen, controller: self)
            panel.orderFrontRegardless()
            return panel
        }
        NSCursor.crosshair.set()
        mouseMoved()
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        NSCursor.arrow.set()
    }

    /// Back to hovering after the comment panel closes.
    func resume() {
        state = .hovering(nil)
        redraw()
        mouseMoved()
    }

    // MARK: - Events from the panels

    var cursor: CGPoint { Geometry.topLeft(fromAppKit: NSEvent.mouseLocation, mainScreenHeight: NSScreen.mainHeight) }

    func mouseMoved() {
        guard case .hovering = state else { return }
        NSCursor.crosshair.set()
        scheduleHitTest(cursor)
    }

    func mouseDown(option: Bool) {
        guard case .hovering = state else { return }
        if option {
            state = .dragging(start: cursor, end: cursor)
            redraw()
        }
    }

    func mouseDragged() {
        guard case .dragging(let start, _) = state else { return }
        state = .dragging(start: start, end: cursor)
        redraw()
    }

    func mouseUp() {
        switch state {
        case .dragging(let start, let end):
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard rect.width >= 4, rect.height >= 4 else {
                state = .hovering(nil)
                mouseMoved()
                return
            }
            Task { await selectRegion(rect) }
        case .hovering:
            let point = cursor
            Task { await selectElement(at: point) }
        case .frozen:
            onClickWhileFrozen?(cursor)
        }
    }

    /// Picks the element at `point` directly, for a click made while the comment panel was open.
    func select(at point: CGPoint) {
        state = .hovering(nil)
        Task { await selectElement(at: point) }
    }

    // MARK: - Hit testing

    /// At most one hit test runs at a time, and at most 30 start per second.
    /// The newest point wins; older queued points are dropped.
    private func scheduleHitTest(_ point: CGPoint) {
        queuedPoint = point
        guard !hitTestRunning else { return }
        hitTestRunning = true
        Task {
            while queuedPoint != nil {
                let wait = hitTestInterval - Date().timeIntervalSince(lastHitTest)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let point = queuedPoint else { break }
                queuedPoint = nil
                lastHitTest = Date()
                let target = await resolve(point)
                if case .hovering = state {
                    state = .hovering(target)
                    redraw()
                }
            }
            hitTestRunning = false
        }
    }

    private func selectElement(at point: CGPoint) async {
        // Hit-test again at the click point, so a stale hover result is never used.
        guard let target = await resolve(point) else { return }
        guard case .hovering = state else { return }
        freeze(target)
    }

    /// Accessibility first; then the real DOM element when the app has a DevTools port.
    private func resolve(_ point: CGPoint) async -> Target? {
        guard let target = await reader.target(at: point) else { return nil }
        let appKitPoint = Geometry.appKit(fromTopLeft: CGRect(origin: point, size: .zero), mainScreenHeight: NSScreen.mainHeight).origin
        let scale = NSScreen.screens.first { $0.frame.contains(appKitPoint) }?.backingScaleFactor ?? 2
        return await devTools.inspect(target, at: point, scale: Double(scale))
    }

    private func selectRegion(_ rect: CGRect) async {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let target: Target
        if let (app, window) = await reader.window(at: center) {
            target = Target(mode: .region, app: app, window: window, frame: rect)
        } else {
            let screen = NSScreen.screens.first { $0.topLeftFrame.contains(center) }?.topLeftFrame ?? rect
            target = Target(
                mode: .region, app: AppInfo(name: "Desktop", bundleId: nil, pid: 0),
                window: WindowInfo(title: nil, id: 0, frame: screen), frame: rect)
        }
        freeze(target)
    }

    private func freeze(_ target: Target) {
        state = .frozen(target)
        redraw()
        NSCursor.arrow.set()
        onSelect?(target)
    }

    private func redraw() {
        panels.forEach { $0.contentView?.needsDisplay = true }
    }
}

final class OverlayPanel: NSPanel {
    private unowned let controller: OverlayController

    init(screen: NSScreen, controller: OverlayController) {
        self.controller = controller
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar (24), below the comment panel.
        level = .statusBar
        isOpaque = false
        // A faint tint shows that annotate mode is on, and makes every pixel take clicks.
        backgroundColor = NSColor.black.withAlphaComponent(0.03)
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        contentView = OverlayView(controller: controller)
    }

    /// A click while hovering may make the panel key, so Esc reaches it. Never while frozen:
    /// the comment panel in Annotator keeps the focus, and Ofide's dictation pastes there.
    override var canBecomeKey: Bool {
        if case .frozen = controller.state { return false }
        return true
    }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            controller.onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

final class OverlayView: NSView {
    private unowned let controller: OverlayController

    init(controller: OverlayController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { controller.mouseMoved() }
    override func mouseDown(with event: NSEvent) { controller.mouseDown(option: event.modifierFlags.contains(.option)) }
    override func mouseDragged(with event: NSEvent) { controller.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller.mouseUp() }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        switch controller.state {
        case .hovering(let target?), .frozen(let target):
            drawTarget(target, in: window)
        case .dragging(let start, let end):
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            drawBox(rect, in: window, color: .systemPurple, dashed: true, label: "Region")
        default:
            break
        }
    }

    private func drawTarget(_ target: Target, in window: NSWindow) {
        switch target.mode {
        case .element: drawBox(target.frame, in: window, color: .controlAccentColor, dashed: false, label: target.overlayLabel)
        case .window: drawBox(target.frame, in: window, color: .systemOrange, dashed: true, label: target.overlayLabel)
        case .region: drawBox(target.frame, in: window, color: .systemPurple, dashed: true, label: target.overlayLabel)
        }
    }

    /// `rect` is in global top-left points.
    private func drawBox(_ rect: CGRect, in window: NSWindow, color: NSColor, dashed: Bool, label: String) {
        let global = Geometry.appKit(fromTopLeft: rect, mainScreenHeight: NSScreen.mainHeight)
        let local = global.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        guard local.intersects(bounds) else { return }

        color.withAlphaComponent(0.12).setFill()
        local.fill()
        let path = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        if dashed { path.setLineDash([6, 4], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        var origin = CGPoint(x: local.minX, y: local.maxY + 4)
        if origin.y + size.height + 4 > bounds.maxY { origin.y = local.minY - size.height - 8 }
        if origin.y < bounds.minY { origin.y = local.maxY - size.height - 8 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 12)
        let background = CGRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        color.setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: origin.x + 5, y: origin.y + 2))
    }
}
