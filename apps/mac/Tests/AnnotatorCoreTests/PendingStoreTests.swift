import Foundation
import Testing

@testable import AnnotatorCore

struct PendingStoreTests {
    let store = PendingStore(root: FileManager.default.temporaryDirectory.appending(path: "annotator-tests-\(UUID().uuidString)"))

    @Test func saveListRemove() throws {
        try store.save(id: "a", body: Data("1".utf8))
        try store.save(id: "b", body: Data("2".utf8))
        #expect(Set(store.pending().map(\.id)) == ["a", "b"])
        store.remove(id: "a")
        #expect(store.pending().map(\.id) == ["b"])
    }

    @Test func failedRecordsLeaveTheRetryQueue() throws {
        try store.save(id: "a", body: Data("1".utf8))
        try store.markFailed(id: "a")
        #expect(store.pending().isEmpty)
        #expect(store.failedCount() == 1)
    }
}

struct HotkeyTests {
    @Test func display() {
        #expect(Hotkey.standard.display == "⌃⌥A")
        #expect(Hotkey(keyCode: 1, modifiers: [.command, .shift], key: "s").display == "⇧⌘S")
    }

    @Test func carbonFlags() {
        #expect(Hotkey.standard.carbonModifiers == (1 << 12) | (1 << 11))
    }

    @Test func needsAModifier() {
        #expect(!Hotkey(keyCode: 0, modifiers: [.shift], key: "A").isValid)
        #expect(Hotkey.standard.isValid)
    }
}
