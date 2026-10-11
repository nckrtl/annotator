import AnnotatorCore
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LocalServerState {
    var busy = false
    var running = false
    var error: String?
}

/// Owns the menu bar item and wires the parts together.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let settings = Settings()
    private let serverState = LocalServerState()
    private var localServer: LocalServer? { settings.server.flatMap { LocalServer(url: $0) } }

    private func refreshServerStatus(autoStart: Bool = false) {
        guard !serverState.busy, let server = localServer else { return }
        serverState.busy = true
        Task {
            defer {
                serverState.busy = false
                if let menu = statusItem.menu { menuNeedsUpdate(menu) }
            }
            do {
                let result = try await server.run("status")
                guard localServer?.state == server.state else { return }
                serverState.running = result.running
                serverState.error = nil
                if autoStart, !result.running {
                    // An existing external server can serve the queue without becoming ours.
                    var request = URLRequest(url: settings.server!)
                    request.timeoutInterval = 2
                    if (try? await HTTP.session(timeout: 15)(request)) == nil {
                        let started = try await server.run("start")
                        serverState.running = started.running
                        queue.start(client: client)
                    }
                }
            } catch { serverState.error = error.localizedDescription }
        }
    }

    @objc private func startServer() { controlServer("start") }
    @objc private func restartServer() { controlServer("restart") }
    @objc private func stopServer() { controlServer("stop") }
    @objc private func showServerLog() {
        guard let server = localServer else { return }
        NSWorkspace.shared.open(server.log)
    }

    private func controlServer(_ command: String) {
        guard !serverState.busy, let server = localServer else { return }
        serverState.busy = true
        serverState.error = nil
        Task {
            defer {
                serverState.busy = false
                if let menu = statusItem.menu { menuNeedsUpdate(menu) }
            }
            do {
                if command == "restart" { _ = try await server.run("stop") }
                let result = try await server.run(command == "restart" ? "start" : command)
                if localServer?.state == server.state { serverState.running = result.running }
                queue.start(client: client)
            } catch {
                serverState.error = error.localizedDescription
                let alert = NSAlert()
                alert.messageText = "Could not \(command) the server"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
    }
    private let reader = AXReader()
    private lazy var overlay = OverlayController(reader: reader)
    private let queue = QueueMonitor()
    private let submitter = Submitter()
    private let projects = ProjectsStore()
    private lazy var t3 = T3Sessions(settings: settings)
    /// The last annotated target, to fill in project rules.
    private var lastTarget: Target?
    private var commentPanel: CommentPanelController?
    private var movingComment = false
    /// The queue connection last used to decide whether to ask the local server if it is running.
    private var serverWatch: QueueMonitor.Connection?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var detailWindows: [String: NSWindow] = [:]

    private var client: AnnotationClient? { settings.server.map { AnnotationClient(base: $0) } }

    func start() {
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        overlay.onSelect = { [weak self] target in self?.select(target) }
        overlay.onClickWhileFrozen = { [weak self] point in self?.moveComment(to: point) }
        queue.onChange = { [weak self] in
            guard let self else { return }
            self.updateButton()
            let connection = self.queue.connection
            if connection != self.serverWatch {
                self.serverWatch = connection
                switch connection {
                case .live, .unreachable, .wrongServer, .polling:
                    self.refreshServerStatus()
                case .connecting, .invalidURL:
                    break
                }
            }
            if let summary = self.queue.summary { self.t3.nudge(summary: summary, projects: self.projects.routes.projects) }
        }
        queue.onReachable = { [weak self] in
            guard let self else { return }
            Task { await self.submitter.retryPending(to: self.client) }
        }
        submitter.onChange = { [weak self] in self?.updateButton() }

        refreshServerStatus(autoStart: settings.serverAutoStart)
        registerHotkey()
        queue.start(client: client)
        Task { await submitter.retryPending(to: client) }
        observeServer()
        observeHotkey()
        updateButton()

        if !Permissions.allGranted { showOnboarding() }
    }

    func reopen() {
        Permissions.allGranted ? showSettings() : showOnboarding()
    }

    // MARK: - Annotate mode

    func toggle() {
        overlay.isVisible ? stopAnnotating() : startAnnotating()
    }

    private func startAnnotating() {
        guard Permissions.allGranted else {
            showOnboarding()
            return
        }
        overlay.show()
        registerEscape()
        updateButton()
    }

    private func stopAnnotating() {
        commentPanel?.onClose = nil
        commentPanel?.close()
        commentPanel = nil
        overlay.hide()
        HotKeyCenter.shared.unregister(.escape)
        updateButton()
    }

    /// Esc is a global hotkey while hovering, so it works without taking focus from the app underneath.
    /// It is released while the comment panel is open, so Esc reaches the panel.
    private func registerEscape() {
        HotKeyCenter.shared.register(.escape, keyCode: 53, modifiers: 0) { [weak self] in self?.stopAnnotating() }
    }

    private func select(_ target: Target) {
        HotKeyCenter.shared.unregister(.escape)
        let model = CommentModel(target: target)
        Task { [weak self] in
            // Capture before the panel appears, so the image shows what the user clicked.
            do {
                model.capture = try await Capture.capture(target.frame)
            } catch {
                model.captureError = "\(error)"
            }
            guard let self, overlay.isVisible else { return }
            let panel = CommentPanelController(model: model)
            panel.ofide = settings.ofideEnabled ? settings.ofideClient() : nil
            panel.autoStart = settings.ofideAutoStart
            panel.onSubmit = { [weak self] model in self?.submit(model) }
            panel.onClose = { [weak self] in self?.commentClosed() }
            commentPanel = panel
            panel.show()
        }
    }

    private func commentClosed() {
        commentPanel = nil
        guard overlay.isVisible else { return }
        overlay.resume()
        registerEscape()
    }

    /// Closes the panel at once and posts in the background. The menu bar shows the result:
    /// the open count goes up, or the icon turns into a warning when the post fails.
    private func submit(_ model: CommentModel) {
        guard !model.posted else { return }
        model.posted = true
        let annotation = Annotation(
            comment: model.text.trimmingCharacters(in: .whitespacesAndNewlines),
            target: model.target,
            screenSize: model.capture?.screenSize ?? .zero,
            screenshot: model.capture?.dataURL,
            project: projects.projectName(for: model.target))
        lastTarget = model.target
        if commentPanel?.model === model { commentPanel?.close() }
        Task { _ = await submitter.submit(annotation, to: client) }
    }

    /// Like the web annotator: a click elsewhere stops dictation, waits for the paste,
    /// submits the open comment, and opens a new one at the click.
    /// An empty comment is dropped. A failure keeps the panel open and says why.
    private func moveComment(to point: CGPoint) {
        guard let panel = commentPanel, !movingComment else { return }
        movingComment = true
        Task {
            defer { movingComment = false }
            let model = panel.model
            guard await panel.finishDictation() else { return }
            guard commentPanel === panel else { return }
            if model.canSubmit { submit(model) } else { panel.close() }
            HotKeyCenter.shared.unregister(.escape)
            overlay.select(at: point)
        }
    }

    // MARK: - Settings

    private func registerHotkey() {
        settings.hotkeyError = HotKeyCenter.shared.register(settings.hotkey) { [weak self] in self?.toggle() }
            .map { "\(self.settings.hotkey.display): \($0)" }
        updateButton()
    }

    private func observeServer() {
        withObservationTracking {
            _ = settings.serverURL
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.serverState.running = false
                self.refreshServerStatus()
                self.queue.start(client: self.client)
                self.observeServer()
            }
        }
    }

    private func observeHotkey() {
        withObservationTracking {
            _ = settings.hotkey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registerHotkey()
                self.observeHotkey()
            }
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let general = SettingsView(settings: settings, serverState: serverState,
                                       startServer: { [weak self] in self?.startServer() },
                                       stopServer: { [weak self] in self?.stopServer() },
                                       restartServer: { [weak self] in self?.restartServer() },
                                       showServerLog: { [weak self] in self?.showServerLog() }) { [weak self] recording in
                guard let self else { return }
                if recording { HotKeyCenter.shared.unregister(.toggle) } else { self.registerHotkey() }
            }
            let view = TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                ProjectsView(store: projects) { [weak self] in self?.lastTarget }
                    .tabItem { Label("Projects", systemImage: "folder") }
            }
            settingsWindow = makeWindow(title: "Annotator Settings", view: view)
        }
        present(settingsWindow)
    }

    @objc private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(
                title: "Annotator Permissions", view: OnboardingView { [weak self] in self?.onboardingWindow?.close() })
        }
        present(onboardingWindow)
    }

    private func makeWindow(title: String, view: some View) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        // The window follows the content's size, also when the content changes.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu bar

    /// One status for the dot in the menu bar and the first line of the menu.
    /// Red: the server cannot be used. Orange: something needs attention. Green: all good.
    private var health: (color: NSColor, title: String) {
        switch queue.connection {
        case .unreachable(let message): return (.systemRed, message)
        case .wrongServer: return (.systemRed, "Not an @nckrtl/annotator server")
        case .invalidURL: return (.systemRed, "The server URL in Settings is not valid")
        case .connecting: return (.systemOrange, "Connecting…")
        case .live, .polling: break
        }
        if submitter.pendingCount > 0 { return (.systemOrange, "Connected · \(submitter.pendingCount) not sent yet") }
        if submitter.failedCount > 0 { return (.systemOrange, "Connected · \(submitter.failedCount) refused") }
        if !Permissions.allGranted { return (.systemOrange, "Connected · permissions missing") }
        if settings.hotkeyError != nil { return (.systemOrange, "Connected · shortcut not registered") }
        return (.systemGreen, queue.connection == .live ? "Connected" : "Connected · polling every 3 s")
    }

    /// The menu bar reads: status dot, icon, open count.
    private func updateButton() {
        guard let button = statusItem.button else { return }
        let symbol = overlay.isVisible ? "highlighter.badge.ellipsis" : "highlighter"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "Annotator")
            ?? NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Annotator")
        icon?.isTemplate = true
        let title = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: health.color, .font: NSFont.systemFont(ofSize: 9)])
        if let icon {
            // A template image in a text attachment follows the menu bar's text color, like a normal icon.
            let attachment = NSTextAttachment()
            attachment.image = icon
            let size = icon.size
            attachment.bounds = CGRect(x: 0, y: -3, width: size.width, height: size.height)
            title.append(NSAttributedString(attachment: attachment))
        }
        let open = queue.summary.map { $0.todo + $0.inProgress } ?? 0
        if open > 0 {
            title.append(NSAttributedString(string: " \(open)", attributes: [.font: NSFont.menuBarFont(ofSize: 0)]))
        }
        button.image = nil
        button.attributedTitle = title
        button.toolTip = "Annotator: \(health.title)"
    }

    private static func dot(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [color])))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: health.title, action: nil, keyEquivalent: "")
        status.attributedTitle = NSAttributedString(
            string: health.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        status.subtitle = settings.serverURL
        status.image = AppController.dot(health.color)
        menu.addItem(status)
        if localServer != nil {
            let control = item(serverState.busy ? "Checking Server…" : (serverState.running ? "Stop Server" : "Start Server"),
                               serverState.running ? #selector(stopServer) : #selector(startServer))
            if serverState.busy { control.action = nil }
            menu.addItem(control)
            if serverState.running {
                let restart = item("Restart Server", #selector(restartServer))
                if serverState.busy { restart.action = nil }
                menu.addItem(restart)
            }
            if let error = serverState.error { menu.addItem(info(error)) }
            if let server = localServer, FileManager.default.fileExists(atPath: server.log.path) {
                menu.addItem(item("View Server Log", #selector(showServerLog)))
            }
        } else {
            menu.addItem(info("Start and stop are available for a local HTTP server."))
        }
        if case .unreachable = queue.connection, submitter.pendingCount == 0 {
            menu.addItem(info("New annotations are saved locally and sent when the server is back."))
        }
        menu.addItem(.separator())
        let toggleTitle = overlay.isVisible ? "Stop Annotating" : "Start Annotating"
        menu.addItem(item("\(toggleTitle)  \(settings.hotkey.display)", #selector(toggleFromMenu)))
        menu.addItem(.separator())

        if !Permissions.allGranted {
            menu.addItem(item("⚠︎ Permissions missing. Fix…", #selector(showOnboarding)))
        }
        if let hotkeyError = settings.hotkeyError {
            menu.addItem(info("⚠︎ Shortcut \(hotkeyError)"))
        }

        if let summary = queue.summary {
            menu.addItem(.sectionHeader(title: "Open \(summary.todo) · In progress \(summary.inProgress)"))
            if summary.open.isEmpty { menu.addItem(info("Nothing open.")) }
            for item in summary.open.prefix(25) { menu.addItem(row(item)) }
            if summary.open.count > 25 { menu.addItem(info("\(summary.open.count - 25) more on the server")) }
            if !summary.open.isEmpty {
                menu.addItem(item("Clear Open Annotations…", #selector(clearOpen)))
            }
            if !summary.finished.isEmpty {
                let done = NSMenuItem(title: "Done (\(summary.done))", action: nil, keyEquivalent: "")
                done.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
                let submenu = NSMenu()
                for item in summary.finished.prefix(50) { submenu.addItem(row(item)) }
                if summary.finished.count > 50 { submenu.addItem(info("\(summary.finished.count - 50) more on the server")) }
                done.submenu = submenu
                menu.addItem(done)
            }
            menu.addItem(.separator())
        }

        if submitter.pendingCount > 0 {
            menu.addItem(.separator())
            menu.addItem(info("⚠︎ \(submitter.pendingCount) annotation(s) not sent yet"))
            if let error = submitter.lastRetryError { menu.addItem(info(error)) }
            menu.addItem(item("Retry Now", #selector(retryNow)))
        }
        if submitter.failedCount > 0 {
            menu.addItem(item("⚠︎ \(submitter.failedCount) annotation(s) refused by the server. Show…", #selector(showFailed)))
        }

        menu.addItem(.separator())
        if settings.t3Enabled { menu.addItem(t3Menu()) }
        menu.addItem(promptMenu())
        menu.addItem(item("Open Server URL", #selector(openServer)))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Quit Annotator", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func row(_ item: QueueItem) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let id = item.id
        menuItem.view = AnnotationRowView(item: item) { [weak self] in self?.showAnnotation(id) }
        return menuItem
    }

    /// One window per annotation; opening it again brings it to the front.
    private func showAnnotation(_ id: String) {
        if detailWindows[id] == nil {
            let number = queue.summary?.item(id: id)?.number.map(String.init) ?? "?"
            let window = makeWindow(title: "Annotation #\(number)", view: AnnotationDetailView(id: id, queue: queue) { [weak self] in
                guard let client = self?.client else { return nil }
                return await client.screenshot(id: id)
            })
            // The view draws its own title bar with the status in it.
            AnnotationDetailView.styleTitleBar(window)
            window.isMovableByWindowBackground = true
            detailWindows[id] = window
        }
        present(detailWindows[id])
    }

    /// A read-only line. Kept enabled, so it stays readable.
    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        return item
    }

    @objc private func toggleFromMenu() { toggle() }

    /// One prompt per project, plus the inbox and everything. Each tells an agent how to work through its part.
    private func promptMenu() -> NSMenuItem {
        projects.reload()
        let menu = NSMenu()
        if let error = projects.error { menu.addItem(info("⚠︎ \(error)")) }
        for project in projects.routes.projects {
            let entry = item(project.name, #selector(copyPrompt(_:)))
            entry.representedObject = project.id
            if project.root.isEmpty { entry.toolTip = "This project has no folder yet; the agent will ask you." }
            menu.addItem(entry)
        }
        if !projects.routes.projects.isEmpty { menu.addItem(.separator()) }
        let inbox = item("\(Project.inbox) (no project)", #selector(copyPrompt(_:)))
        inbox.representedObject = "inbox"
        menu.addItem(inbox)
        let all = item("All Annotations", #selector(copyPrompt(_:)))
        all.representedObject = "all"
        menu.addItem(all)
        menu.addItem(.separator())
        menu.addItem(item("Edit Projects…", #selector(showSettings)))
        let parent = NSMenuItem(title: "Copy Agent Prompt", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        parent.submenu = menu
        return parent
    }

    /// Start a session per project, or open the one already running.
    private func t3Menu() -> NSMenuItem {
        projects.reload()
        let menu = NSMenu()
        if let error = t3.lastError { menu.addItem(info("⚠︎ \(AXElementInfo.truncate(error, to: 90))")) }
        for project in projects.routes.projects {
            let start = item(t3.hasSession(project) ? "New Session for \(project.name)" : project.name, #selector(startT3(_:)))
            start.representedObject = project.id
            if project.root.isEmpty {
                start.action = nil
                start.toolTip = "Set a folder for this project first."
            }
            menu.addItem(start)
            if t3.hasSession(project) {
                let open = item("Open \(project.name) Session", #selector(openT3(_:)))
                open.representedObject = project.id
                open.indentationLevel = 1
                menu.addItem(open)
            }
        }
        if projects.routes.projects.isEmpty { menu.addItem(info("Add a project first.")) }
        menu.addItem(.separator())
        menu.addItem(item("Copy Pairing URL", #selector(copyPairingURL)))
        menu.addItem(item("Edit Projects…", #selector(showSettings)))
        let parent = NSMenuItem(title: "Conn Sessions", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        parent.submenu = menu
        return parent
    }

    @objc private func startT3(_ sender: NSMenuItem) {
        guard let project = projects.routes.projects.first(where: { $0.id == sender.representedObject as? String }) else { return }
        let prompt = AgentPrompt.make(server: settings.serverURL, scope: .project(project))
        Task { await t3.start(project, prompt: prompt) }
    }

    /// For adding the session server in a Conn window: Settings › Connections › Add environment.
    @objc private func copyPairingURL() {
        Task {
            guard let url = await t3.pairingURL() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Pairing URL copied"
            alert.informativeText = "In Conn, open Settings › Connections › Add environment, choose the remote option and paste it. It works once and expires in 15 minutes."
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func openT3(_ sender: NSMenuItem) {
        guard let project = projects.routes.projects.first(where: { $0.id == sender.representedObject as? String }) else { return }
        Task { await t3.open(project) }
    }

    @objc private func copyPrompt(_ sender: NSMenuItem) {
        let key = sender.representedObject as? String
        let scope: AgentPrompt.Scope
        switch key {
        case "inbox": scope = .inbox
        case "all": scope = .all
        default:
            guard let project = projects.routes.projects.first(where: { $0.id == key }) else { return }
            scope = .project(project)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPrompt.make(server: settings.serverURL, scope: scope), forType: .string)
    }

    /// Deletes every to-do and in-progress annotation on the server, after a confirmation. Done ones stay.
    @objc private func clearOpen() {
        guard let summary = queue.summary, !summary.open.isEmpty, let client else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(summary.open.count) open annotation(s)?"
        var detail = "\(summary.todo) to do and \(summary.inProgress) in progress will be removed from the server. "
        if summary.inProgress > 0 { detail += "Agents working on them can no longer complete them. " }
        alert.informativeText = detail + "Done annotations stay. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = summary.open.map(\.id)
        Task {
            var failed = 0
            for id in ids where !(await client.delete(id: id)) { failed += 1 }
            queue.refreshNow(client)
            guard failed > 0 else { return }
            let error = NSAlert()
            error.messageText = "\(failed) annotation(s) could not be deleted"
            error.informativeText = "The server did not accept the request. Check that it is running, then try again."
            NSApp.activate()
            error.runModal()
        }
    }

    @objc private func retryNow() {
        Task { await submitter.retryPending(to: client) }
    }

    @objc private func showFailed() {
        NSWorkspace.shared.open(submitter.store.failedDirectory)
    }

    @objc private func openServer() {
        guard let url = settings.server else { return }
        NSWorkspace.shared.open(url)
    }
}
