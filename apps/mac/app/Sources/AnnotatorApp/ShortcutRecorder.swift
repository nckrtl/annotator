import AppKit
import Observation

/// Records one global shortcut. Recording ends on Escape, a valid shortcut, plain typing,
/// a click, or when the app deactivates. Only Escape and a valid shortcut are consumed.
@MainActor @Observable final class ShortcutRecorder {
    private(set) var recording = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var inactive: NSObjectProtocol?
    @ObservationIgnored private var changed: (Bool) -> Void = { _ in }
    @ObservationIgnored private var selected: (UInt16, Int) -> Void = { _, _ in }
    /// When a click ended recording. The click that ends it on the record button must not start it again.
    @ObservationIgnored private var clickEnded: TimeInterval = -1

    /// Starts recording, or stops it when it runs or a click just ended it.
    func toggle(changed: @escaping (Bool) -> Void, selected: @escaping (UInt16, Int) -> Void) {
        if recording { stop(); return }
        if ProcessInfo.processInfo.systemUptime - clickEnded < 1 { clickEnded = -1; return }
        start(changed: changed, selected: selected)
    }

    func start(changed: @escaping (Bool) -> Void, selected: @escaping (UInt16, Int) -> Void) {
        stop()
        self.changed = changed; self.selected = selected
        recording = true; changed(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let passes = MainActor.assumeIsolated { self.map { $0.handle(event) != nil } ?? true }
            return passes ? event : nil
        }
        inactive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Returns the event to pass it on, or nil to consume it.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard recording else { return event }
        guard event.type == .keyDown else { clickEnded = ProcessInfo.processInfo.systemUptime; stop(); return event }
        if event.keyCode == 53 { stop(); return nil }
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else { stop(); return event }
        let modifiers = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
        let selected = self.selected
        stop()
        selected(event.keyCode, modifiers)
        return nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let inactive { NotificationCenter.default.removeObserver(inactive) }; inactive = nil
        let changed = self.changed
        self.changed = { _ in }; selected = { _, _ in }
        if recording { recording = false; changed(false) }
    }
}
