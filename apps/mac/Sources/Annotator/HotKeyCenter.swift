import AnnotatorCore
import Carbon.HIToolbox

/// Global shortcuts through Carbon `RegisterEventHotKey`. They need no permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Slot: UInt32 {
        case toggle = 1
        case escape = 2
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Returns an error message when macOS refuses the shortcut, for example because another app owns it.
    @discardableResult
    func register(_ slot: Slot, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> String? {
        installHandler()
        unregister(slot)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x414E_4E54, id: slot.rawValue)  // "ANNT"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return status == eventHotKeyExistsErr
                ? "Another app already uses this shortcut."
                : "macOS refused the shortcut (error \(status))."
        }
        refs[slot.rawValue] = ref
        handlers[slot.rawValue] = handler
        return nil
    }

    func register(_ hotkey: Hotkey, handler: @escaping () -> Void) -> String? {
        register(.toggle, keyCode: hotkey.keyCode, modifiers: hotkey.carbonModifiers, handler: handler)
    }

    func unregister(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot.rawValue) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: slot.rawValue)
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                // Carbon delivers hotkey events on the main thread.
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id.id) }
                return noErr
            },
            1, &type, nil, nil)
    }
}
