import AppKit
import Carbon
import AnnotatorCore

@MainActor final class Hotkeys {
    unowned let model: AppModel
    private var refs: [Int: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    init(model: AppModel) {
        self.model = model
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let slot = Int(id.id)
            MainActor.assumeIsolated {
                let keys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
                if slot == 2 { keys.model.cancelComment() }
                else { keys.model.act("hotkey_pressed", ["slot": .number(Double(slot))]) }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ value: JSON) {
        let slot = value["slot"].int; unregister(slot)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(value["keyCode"].int), UInt32(value["modifiers"].int), EventHotKeyID(signature: 0x414E4E4F, id: UInt32(slot)), GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[slot] = ref }
        if slot == 1 { model.act("hotkey_error", ["message": status == noErr ? .null : .string("The shortcut could not be registered (\(status)). Choose another in Settings.")]) }
    }
    func unregister(_ slot: Int) { if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) } }
}
