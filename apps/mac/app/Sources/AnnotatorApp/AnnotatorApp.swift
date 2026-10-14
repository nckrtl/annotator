import SwiftUI
import AppKit
import DesignKit

@main struct AnnotatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    var body: some Scene {
        Window("Annotator", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: Kit.windowMinSize.width, minHeight: Kit.windowMinSize.height)
                .ignoresSafeArea()
                .background(KitWindowChrome { model.window = $0 })
                .background(WindowOpener(model: model))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Kit.windowSize.width, height: Kit.windowSize.height)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.navigate("settings") }.keyboardShortcut(",") }
            CommandGroup(after: .newItem) {
                Button("Annotate screen") { model.act("toggle_annotating") }.keyboardShortcut("a", modifiers: [.control, .option])
                Button("Find") { if model.page == "settings" { model.navigate("all") }; model.searching = true }.keyboardShortcut("f")
            }
        }
        MenuBarExtra {
            MenuPanel(model: model).kitAppearance()
                .background(WindowOpener(model: model))
                .onAppear { model.act("menu_opened") }
        } label: {
            KitMenuBarIconView(.annotator, variant: model.isAnnotating ? .active : .standard, size: 18)
                .accessibilityLabel(model.isAnnotating ? "Annotator: annotating" : "Annotator")
            let count = model.state["queue"]["todo"].int + model.state["queue"]["inProgress"].int
            if count > 0 { Text("\(count)") }
        }.menuBarExtraStyle(.window)
    }
}
private struct WindowOpener: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View { Color.clear.onAppear { model.showWindow = { openWindow(id: "main") } } }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["ANNOTATOR_DICTATION_CHECK"] {
            Task { await DictationCheck.run(AppModel.shared, directory: directory) }
        }
        if let directory = ProcessInfo.processInfo.environment["ANNOTATOR_MENU_CHECK"] {
            Task { await MenuCheck.run(AppModel.shared, directory: directory) }
        }
        if let directory = ProcessInfo.processInfo.environment["ANNOTATOR_UI_SNAPSHOTS"] {
            Task { await Demo.capture(AppModel.shared, directory: directory) }
        }
        #endif
    }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.bridge.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { AppModel.shared.navigate("all"); return true }
}

struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { let view = Reader(); view.found = found; return view }
    func updateNSView(_ view: NSView, context: Context) {}
    final class Reader: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { found?(window) } }
    }
}
