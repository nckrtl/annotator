import AppKit
import Testing
@testable import AnnotatorApp

@MainActor private func key(_ code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!
}

@MainActor @Test func recorderDoesNotSwallowPlainTyping() {
    let recorder = ShortcutRecorder(); var changes: [Bool] = []; var selected = false
    recorder.start(changed: { changes.append($0) }, selected: { _, _ in selected = true })
    let event = key()
    #expect(recorder.handle(event) === event)
    #expect(!recorder.recording)
    #expect(changes == [true, false])
    #expect(!selected)
}

@MainActor @Test func recorderEndsOnClickAndAppDeactivation() {
    let recorder = ShortcutRecorder()
    for deactivate in [false, true] {
        recorder.start(changed: { _ in }, selected: { _, _ in Issue.record("Unexpected shortcut") })
        if deactivate {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        } else {
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            #expect(recorder.handle(click) === click)
        }
        #expect(!recorder.recording)
        let event = key(flags: [.command])
        #expect(recorder.handle(event) === event)
    }
}

@MainActor @Test func recorderConsumesOnlyEscapeOrAValidShortcut() {
    let recorder = ShortcutRecorder(); var shortcut: (UInt16, Int)?
    recorder.start(changed: { _ in }, selected: { shortcut = ($0, $1) })
    #expect(recorder.handle(key(flags: [.control, .option, .shift])) == nil)
    #expect(shortcut?.0 == 0)
    #expect(shortcut?.1 == 6656)
    #expect(!recorder.recording)
    shortcut = nil
    recorder.start(changed: { _ in }, selected: { shortcut = ($0, $1) })
    #expect(recorder.handle(key(53)) == nil)
    #expect(shortcut == nil)
    #expect(!recorder.recording)
}
