import AppKit
import SwiftUI
import AnnotatorCore

@MainActor @Observable final class AppModel {
    static let shared = AppModel()
    /// Annotate mode leaves Annotator's own windows as they are, so they can be annotated too.
    var state: JSON = .object([:])
    var settings: JSON = .object([:])
    var projects: [JSON] = []
    var projectsError = ""
    var projectsSaving = false
    var selectedProjectID = ""
    var selectedProject: JSON? { projects.first { $0["id"].string == selectedProjectID } }
    var items: [JSON] = []
    var page = "all"
    var selected = ""
    /// Rows picked with ⌘- or ⇧-click, for deleting several at once. Cleared by a plain click.
    var marked: Set<String> = []
    var search = ""
    var searching = false
    var error: String? {
        didSet { if error != nil { showWindow?(); window?.makeKeyAndOrderFront(nil); NSApp.activate() } }
    }
    var comment = ""
    var target: JSON = .null
    var voice = Dictation()
    var demoDictation: String?
    var dictation: String { demoDictation ?? voice.phase }
    var commentError: String?
    var commentBusy = false
    var isAnnotating: Bool { state["annotating"].bool || state["commentOpen"].bool }
    var missingPermissions: [Permission] { Permission.missing(in: state["permissions"]) }
    var permissionRefreshError: String?
    #if DEBUG
    var demo = ProcessInfo.processInfo.environment["ANNOTATOR_UI_DEMO"] == "1"
    @ObservationIgnored var demoRequest: ((String, [String: JSON]) async throws -> JSON)?
    #else
    let demo = false
    #endif
    @ObservationIgnored let bridge = Bridge()
    @ObservationIgnored var window: NSWindow?
    @ObservationIgnored var showWindow: (() -> Void)?
    @ObservationIgnored var panels: Panels?
    @ObservationIgnored var hotkeys: Hotkeys?
    var selectedItem: JSON? { items.first { $0["id"].string == selected } }
    var pageTitle: String {
        if page == "all" { return "Annotations" }
        if page == "open" { return "Open" }
        if page == "done" { return "Finished" }
        return projects.first { "project:" + $0["id"].string == page }?["name"].string ?? "Annotations"
    }
    var filtered: [JSON] { AnnotationCollection.items(items, page: page, projects: projects, search: search) }
    func start() {
        panels = Panels(model: self); hotkeys = Hotkeys(model: self)
        voice.call = { [weak self] action in guard let self else { throw CancellationError() }; return try await self.call("operator", ["action": .string(action)]) }
        voice.text = { [weak self] in self?.comment ?? "" }
        voice.focus = { [weak self] in
            guard let panels = self?.panels else { throw CancellationError() }
            try await panels.prepareDictation()
        }
        voice.releaseOverlay = { [weak self] _ in self?.releaseOverlay() }
        voice.reportError = { [weak self] in self?.commentError = $0 }
        if demo { Demo.populate(self); return }
        bridge.onEvent = { [weak self] event, value in self?.event(event, value) }
        do {
            let executable = Bundle.main.resourceURL!.appendingPathComponent("annotator-core")
            try bridge.start(executable: executable, environment: ProcessInfo.processInfo.environment)
            Task { await load() }
        } catch { self.error = error.localizedDescription }
    }
    func load() async {
        do {
            settings = try await call("get_settings")
            state = try await call("get_state")
            items = try await call("get_queue").array
            await loadProjects()
        } catch { self.error = error.localizedDescription }
    }
    func loadProjects() async {
        do { let value = try await call("get_projects"); projects = value["routes"]["projects"].array; projectsError = value["error"].string }
        catch { projectsError = error.localizedDescription }
    }
    func call(_ command: String, _ args: [String: JSON] = [:]) async throws -> JSON {
        #if DEBUG
        if demo, let demoRequest { return try await demoRequest(command, args) }
        #endif
        if demo { return .null }
        return try await bridge.request(command, .object(args))
    }
    func act(_ command: String, _ args: [String: JSON] = [:]) {
        Task { do { _ = try await call(command, args) } catch { self.error = error.localizedDescription } }
    }
    func requestPermission(_ permission: Permission) {
        panels?.menu?.orderOut(nil)
        act("request_permission", ["kind": .string(permission.rawValue)])
    }
    func refreshPermissions() async {
        #if DEBUG
        guard !demo || demoRequest != nil else { return }
        #endif
        do {
            state["permissions"] = try await call("get_permissions")
            permissionRefreshError = nil
        } catch {
            // Background checks must not activate the library over an open comment.
            permissionRefreshError = error.localizedDescription
        }
    }
    /// Activation for the comment field must not also reveal the library.
    /// The comment activates Annotator, which would raise the library over the annotated app.
    /// When the annotation is of Annotator itself, the library stays.
    func hideLibraryForAnnotation() {
        guard target["bundleId"].string != Bundle.main.bundleIdentifier else { return }
        window?.orderOut(nil)
        panels?.menu?.orderOut(nil)
    }
    func navigate(_ page: String, id: String? = nil) {
        self.page = page; search = ""; searching = false
        if let id { selected = id }
        if page.hasPrefix("project:") { selectedProjectID = String(page.dropFirst("project:".count)) }
        panels?.menu?.orderOut(nil); showWindow?(); window?.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    func saveSettings() async {
        do { settings = try await call("save_settings", ["settings": settings]) } catch { self.error = error.localizedDescription }
    }
    func event(_ event: String, _ value: JSON) {
        switch event {
        case "state": state = value
        case "queue": items = value.array
        case "navigate": navigate(value["page"].string, id: value["id"] == .null ? nil : value["id"].string)
        case "onboarding": panels?.permissions()
        case "alert": error = value["title"].string + ": " + value["message"].string
        case "bridge-error":
            voice.cancel(); panels?.hideComment(); hotkeys?.unregister(2); bridge.stop()
            DictationLog.write("overlay-release core-stopped")
            error = value.string
        case "hide-menu": panels?.menu?.orderOut(nil)
        case "comment-opened": voice.cancel(); target = value; hideLibraryForAnnotation(); comment = ""; commentError = value["captureError"] == .null ? nil : value["captureError"].string
        case "show-comment": panels?.showComment(value)
        case "hide-comment": panels?.hideComment()
        case "comment-cancel": cancelDictation(); panels?.hideComment()
        case "comment-finish": Task { await submit(moving: true) }
        case "register-hotkey": hotkeys?.register(value)
        case "unregister-hotkey": hotkeys?.unregister(value.int)
        case "quit": NSApp.terminate(nil)
        case "relaunch":
            let url = Bundle.main.bundleURL
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
            do { try p.run(); NSApp.terminate(nil) } catch { self.error = error.localizedDescription }
        default: break
        }
    }
    func cancelDictation() { voice.cancel() }
    func releaseOverlay() { act("release_overlay") }
    func cancelComment() {
        cancelDictation(); panels?.hideComment(); hotkeys?.unregister(2); commentBusy = false
        act("stop_annotating")
    }
    func startDictation() { voice.start() }
    func finishDictation() async throws { try await voice.finish() }
    func submit(moving: Bool = false) async {
        guard !commentBusy else { return }; commentBusy = true; defer { commentBusy = false }
        do {
            try await finishDictation()
            if moving { _ = try await call("comment_finish_done", ["submit": .bool(!comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), "text": .string(comment), "keep": .bool(false)]) }
            else { _ = try await call("submit_comment", ["text": .string(comment)]) }
        } catch is CancellationError {
            releaseOverlay(); return
        } catch {
            commentError = error.localizedDescription
            if moving { act("comment_finish_done", ["submit": .bool(false), "text": .string(comment), "keep": .bool(true)]) }
        }
    }
}
