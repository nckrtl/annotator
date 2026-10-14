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
    /// The screen as it was when annotate mode started. Empty until the capture is done, or when it failed.
    private(set) var stills: [Capture.Still] = []
    /// Open menus and flyouts as they were then. They close once the comment panel takes focus.
    private var frozen = FrozenElements()
    /// The frozen screen stays behind the comment panel. It takes no hover; a click on it removes it.
    private(set) var passive = false
    /// Mapping and freezing; the panels follow.
    private var preparing = false
    var onSelect: ((Target) -> Void)?
    /// A click on the overlay while the comment panel is open: finish that comment, then move here.
    var onClickWhileFrozen: ((CGPoint) -> Void)?
    /// Esc while an overlay panel is key. A backup for Annotator's global Esc hotkey.
    var onEscape: (() -> Void)?

    private lazy var watchdog = OverlayWatchdog(forceRelease: {
        logOverlayRelease("main-actor-unresponsive")
        exit(70)
    }) { [weak self] in
        guard let self, self.isVisible else { return }
        self.hide(reason: "watchdog")
        emit(["type": "overlay-timeout"])
    }
    private(set) var generation = 0

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

    /// Like the system screenshot tool. Nothing takes focus, so open menus stay open while the helper
    /// maps the focused window and the menus, then freezes the screen, then shows the selector over both.
    /// Menus stay visible and selectable after they close. Unmapped windows keep live hit testing.
    func show() {
        if passive { hide(reason: "restart") }
        guard panels.isEmpty, !preparing else { return }
        generation += 1
        preparing = true
        let session = generation
        Task {
            let recorded = await reader.frozenElements()
            guard session == generation else { return }
            let captured: [Capture.Still]
            do {
                captured = try await Capture.stills()
            } catch {
                captured = []
                emit(["type": "log", "message": "The screen did not freeze: \(error)"])
            }
            guard session == generation else { return }
            preparing = false
            frozen = recorded
            stills = captured
            state = .hovering(nil)
            watchdog.activity()
            panels = NSScreen.screens.map { screen in
                let panel = OverlayPanel(screen: screen, controller: self)
                panel.orderFrontRegardless()
                return panel
            }
            NSCursor.crosshair.set()
            mouseMoved()
        }
    }

    func hide(reason: String = "cancel-or-release") {
        generation += 1
        preparing = false
        watchdog.stop()
        if isVisible { logOverlayRelease(reason) }
        queuedPoint = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        stills = []
        frozen = FrozenElements()
        passive = false
        NSCursor.arrow.set()
    }

    /// Annotator ended selection. With `keepBackdrop`, a frozen screen stays behind the comment.
    func release(keepBackdrop: Bool) {
        if keepBackdrop, passive { return }
        hide()
    }

    /// The still of the screen that `window` covers.
    func still(for window: NSWindow) -> CGImage? {
        let frame = Geometry.topLeft(fromAppKit: window.frame, mainScreenHeight: NSScreen.mainHeight)
        return stills.first { abs($0.bounds.minX - frame.minX) < 1 && abs($0.bounds.minY - frame.minY) < 1 }?.image
    }

    /// Back to hovering after the comment panel closes.
    func resume() {
        passive = false
        watchdog.activity()
        state = .hovering(nil)
        redraw()
        mouseMoved()
    }

    // MARK: - Events from the panels

    var cursor: CGPoint { Geometry.topLeft(fromAppKit: NSEvent.mouseLocation, mainScreenHeight: NSScreen.mainHeight) }

    func mouseMoved() {
        if isVisible, !passive { watchdog.activity() }
        guard case .hovering = state else { return }
        NSCursor.crosshair.set()
        scheduleHitTest(cursor)
    }

    func mouseDown(option: Bool) {
        if !passive { watchdog.activity() }
        guard case .hovering = state else { return }
        if option {
            state = .dragging(start: cursor, end: cursor)
            redraw()
        }
    }

    func mouseDragged() {
        if !passive { watchdog.activity() }
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
            if passive { hide(reason: "backdrop-click") } else { onClickWhileFrozen?(cursor) }
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
                let target = await resolve(point, dom: false)
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
        let session = generation
        guard let target = await resolve(point, dom: true), session == generation, isVisible else { return }
        guard case .hovering = state else { return }
        freeze(target)
    }

    /// Accessibility first. `dom` asks DevTools for the real element. Hover leaves it off:
    /// a probe on every move stalls the highlight and runs script in the page.
    private func resolve(_ point: CGPoint, dom: Bool) async -> Target? {
        // A click in a mapped app window reads it live, for the web URL and DOM; menus may close, so the map answers.
        if case .mapped(let target, let menu) = frozen.lookup(point), menu || !dom { return target }
        guard let target = await reader.target(at: point, text: dom) else { return nil }
        guard dom else { return target }
        let appKitPoint = Geometry.appKit(fromTopLeft: CGRect(origin: point, size: .zero), mainScreenHeight: NSScreen.mainHeight).origin
        let scale = NSScreen.screens.first { $0.frame.contains(appKitPoint) }?.backingScaleFactor ?? 2
        return await devTools.inspect(target, at: point, scale: Double(scale))
    }

    private func selectRegion(_ rect: CGRect) async {
        let session = generation
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
        guard session == generation, isVisible else { return }
        freeze(target)
    }

    /// With a frozen screen, the overlay stays as a passive backdrop; otherwise it goes before capture.
    private func freeze(_ target: Target) {
        if stills.isEmpty {
            hide(reason: "target-selected")
        } else {
            passive = true
            watchdog.stop()
            queuedPoint = nil
        }
        state = .frozen(target)
        redraw()
        NSCursor.arrow.set()
        onSelect?(target)
    }

    #if DEBUG
    func showDemo(_ target: Target) { state = .frozen(target) }
    #endif

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
        // Above open menus (101), like the system screenshot tool, and below the comment panel.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
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
    /// the comment panel in Annotator keeps the focus, and Operator's dictation pastes there.
    override var canBecomeKey: Bool {
        if case .frozen = controller.state { return false }
        return true
    }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            controller.hide(reason: "escape")
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
        if let still = controller.still(for: window) {
            NSGraphicsContext.current?.cgContext.draw(still, in: bounds)
        }
        switch controller.state {
        case .hovering(let target?), .frozen(let target):
            drawTarget(target, in: window)
        case .dragging(let start, let end):
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            drawBox(rect, in: window, color: .labelColor, dashed: true, label: "Region")
        default:
            break
        }
    }

    private func drawTarget(_ target: Target, in window: NSWindow) {
        switch target.mode {
        case .element: drawBox(target.frame, in: window, color: .labelColor, dashed: false, label: target.overlayLabel)
        case .window: drawBox(target.frame, in: window, color: .labelColor, dashed: true, label: target.overlayLabel)
        case .region: drawBox(target.frame, in: window, color: .labelColor, dashed: true, label: target.overlayLabel)
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
        // A contrasting halo keeps the neutral outline visible over arbitrary screen content.
        path.lineWidth = 4
        NSColor.textBackgroundColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.lineWidth = 2
        color.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.textBackgroundColor,
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
