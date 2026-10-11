import AppKit
import Inject

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        _ = InjectConfiguration.load
        #endif
        controller.start()
    }

    /// Opening the app again shows a window, in case the menu bar hides the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.reopen()
        return false
    }
}

/// An accessory app has no menu bar, but ⌘V, ⌘C, ⌘A and ⌘Z only work through menu key equivalents.
/// Ofide pastes with ⌘V, so without this menu dictation never reaches the comment field.
@MainActor
func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let main = NSMenu()
    main.addItem(withTitle: "Annotator", action: nil, keyEquivalent: "")
    let item = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
    item.submenu = edit
    return main
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = editMenu()
    app.run()
}
