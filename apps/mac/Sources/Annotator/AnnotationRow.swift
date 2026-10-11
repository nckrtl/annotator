import AnnotatorCore
import AppKit

/// One annotation in the menu: a status icon, the number and comment, and a spinner while an agent works on it.
/// A custom view, because a plain menu item cannot show a spinner. It draws its own highlight.
final class AnnotationRowView: NSView {
    private let action: @MainActor @Sendable () -> Void
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()

    static let width: CGFloat = 360

    init(item: QueueItem, action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        super.init(frame: CGRect(x: 0, y: 0, width: AnnotationRowView.width, height: 24))

        icon.image = NSImage(systemSymbolName: AnnotationRowView.symbol(for: item), accessibilityDescription: item.status)
        icon.contentTintColor = item.needsAnswer ? .systemOrange : .secondaryLabelColor
        icon.frame = CGRect(x: 14, y: 4, width: 16, height: 16)
        addSubview(icon)

        let comment = item.comment.replacingOccurrences(of: "\n", with: " ")
        label.stringValue = "#\(item.number.map(String.init) ?? "?")  \(comment)"
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.frame = CGRect(x: 38, y: 3, width: AnnotationRowView.width - 38 - 36, height: 18)
        addSubview(label)

        if item.isInProgress {
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.frame = CGRect(x: AnnotationRowView.width - 30, y: 4, width: 16, height: 16)
            spinner.startAnimation(nil)
            addSubview(spinner)
        }
        toolTip = item.needsAnswer ? "The agent asked a question: \(item.summary ?? "")" : item.comment
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func symbol(for item: QueueItem) -> String {
        if item.needsAnswer { return "questionmark.circle.fill" }
        switch item.status {
        case "todo": return "circle"
        case "in_progress": return "circle.dotted"
        default: return "checkmark.circle.fill"
        }
    }

    private var highlighted: Bool { enclosingMenuItem?.isHighlighted ?? false }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The menu changes the highlight while tracking; redraw on every mouse move inside it.
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        // Close the whole menu, also when this row sits in the Done submenu.
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        // Let the menu close before a window opens.
        DispatchQueue.main.async(execute: action)
    }
}
