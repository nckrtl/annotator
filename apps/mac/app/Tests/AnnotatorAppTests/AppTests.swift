import AppKit
import Testing
import AnnotatorCore
@testable import AnnotatorApp

@MainActor private func key(_ code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!
}
@MainActor private func click() -> NSEvent {
    NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

@MainActor @Test func recorderPassesPlainTypingOnAndStops() {
    let recorder = ShortcutRecorder(); var changes: [Bool] = []; var selected = false
    for flags: NSEvent.ModifierFlags in [[], [.shift]] {
        recorder.start(changed: { changes.append($0) }, selected: { _, _ in selected = true })
        let event = key(flags: flags)
        #expect(recorder.handle(event) === event)
        #expect(!recorder.recording)
    }
    #expect(changes == [true, false, true, false])
    #expect(!selected)
}

@MainActor @Test func recorderEndsOnClickDeactivationAndStop() {
    let recorder = ShortcutRecorder()
    for end in ["click", "deactivate", "stop"] {
        var changes: [Bool] = []
        recorder.start(changed: { changes.append($0) }, selected: { _, _ in Issue.record("Unexpected shortcut") })
        switch end {
        case "click": let event = click(); #expect(recorder.handle(event) === event)
        case "deactivate": NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        default: recorder.stop()
        }
        #expect(!recorder.recording)
        #expect(changes == [true, false])
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

@MainActor @Test func clickOnTheRecordButtonStopsWithoutRestarting() {
    let recorder = ShortcutRecorder()
    recorder.toggle(changed: { _ in }, selected: { _, _ in })
    #expect(recorder.recording)
    // The click's mouse down ends recording; the button's action then runs on mouse up.
    _ = recorder.handle(click())
    recorder.toggle(changed: { _ in }, selected: { _, _ in })
    #expect(!recorder.recording)
    recorder.toggle(changed: { _ in }, selected: { _, _ in })
    #expect(recorder.recording)
    recorder.toggle(changed: { _ in }, selected: { _, _ in })
    #expect(!recorder.recording)
}

@MainActor @Test func cancelledHasItsOwnFinishedStatus() {
    let status = { (value: String) in AnnotationStatus(.object(["status": .string(value)])) }
    #expect(status("cancelled").label == "Cancelled")
    #expect(status("cancelled").icon == .clear)
    #expect(status("in_progress").label == "In progress")
    #expect(status("todo").label == "To do")
    #expect(status("done").label == "Done")
    #expect(AnnotationStatus(.object(["status": .string("todo"), "question": .bool(true)])).label == "Question")
}

@MainActor @Test func cachedTimestampsMatchAFreshFormatter() {
    for zone in ["UTC", "Asia/Tokyo", "UTC"] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        let now = Date(timeIntervalSince1970: 1_791_400_000)
        let fresh = DateFormatter(); fresh.calendar = calendar; fresh.timeZone = calendar.timeZone; fresh.setLocalizedDateFormatFromTemplate("jmm")
        let today = now.addingTimeInterval(-60), yesterday = now.addingTimeInterval(-86_400), older = now.addingTimeInterval(-5 * 86_400)
        #expect(MenuAnnotationRow.timestamp(today.timeIntervalSince1970 * 1000, now: now, calendar: calendar) == fresh.string(from: today))
        #expect(MenuAnnotationRow.timestamp(yesterday.timeIntervalSince1970 * 1000, now: now, calendar: calendar) == fresh.string(from: yesterday) + " - Yesterday")
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        #expect(MenuAnnotationRow.timestamp(older.timeIntervalSince1970 * 1000, now: now, calendar: calendar) == fresh.string(from: older) + " - " + day.string(from: older))
        #expect(MenuAnnotationRow.timestamp(0, now: now, calendar: calendar) == "")
    }
}
