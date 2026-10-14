import AppKit
import Observation

/// Recording ends when focus moves, the user types normally, or a shortcut is selected.
@MainActor @Observable final class ShortcutRecorder {
    private(set) var recording = false
    private var monitor: Any?
    private var inactive: NSObjectProtocol?
    private var changed: (Bool) -> Void = { _ in }
    private var selected: (UInt16, Int) -> Void = { _, _ in }

    func start(changed: @escaping (Bool) -> Void, selected: @escaping (UInt16, Int) -> Void) {
        stop()
        self.changed = changed; self.selected = selected
        recording = true; changed(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handle(event) == nil && self != nil
            }
            return consumed ? nil : event
        }
        inactive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard recording else { return event }
        guard event.type == .keyDown else { stop(); return event }
        if event.keyCode == 53 { stop(); return nil }
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            stop(); return event
        }
        let modifiers = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
        let selected = self.selected
        stop()
        selected(event.keyCode, modifiers)
        return nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let inactive { NotificationCenter.default.removeObserver(inactive) }; inactive = nil
        if recording { recording = false; changed(false) }
        changed = { _ in }; selected = { _, _ in }
    }
}
