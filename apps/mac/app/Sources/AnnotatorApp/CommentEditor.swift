import SwiftUI
import AppKit

/// System text input keeps paste, dictation and input-method composition native.
struct CommentEditor: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let field = scroll.documentView as! NSTextView
        field.isRichText = false; field.drawsBackground = false; scroll.drawsBackground = false
        field.font = .systemFont(ofSize: 14); field.textColor = .labelColor
        field.textContainerInset = NSSize(width: 4, height: 6)
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.delegate = context.coordinator; field.setAccessibilityLabel("Comment")
        context.coordinator.field = field
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .focusComment, object: nil, queue: .main) { [weak field] _ in
            MainActor.assumeIsolated { _ = field?.window?.makeFirstResponder(field) }
        }
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        let field = scroll.documentView as! NSTextView
        if field.string != text { field.string = text; field.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: CommentEditor
        weak var field: NSTextView?
        var observer: NSObjectProtocol?
        init(_ owner: CommentEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) { owner.text = field?.string ?? "" }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { owner.cancel(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(), NSApp.currentEvent?.modifierFlags.contains(.shift) != true { owner.submit(); return true }
            return false
        }
    }
}
