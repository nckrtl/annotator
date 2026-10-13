import AppKit
import SwiftUI
import AnnotatorCore

@MainActor @Observable final class AppModel {
    static let shared = AppModel()
    var state: JSON = .object([:])
    var settings: JSON = .object([:])
    var projects: [JSON] = []
    var projectsError = ""
    var items: [JSON] = []
    var page = "all"
    var selected = ""
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
    #if DEBUG
    var demo = ProcessInfo.processInfo.environment["ANNOTATOR_UI_DEMO"] == "1"
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
        voice.call = { [weak self] action in guard let self else { throw CancellationError() }; return try await self.call("ofide", ["action": .string(action)]) }
        voice.text = { [weak self] in self?.comment ?? "" }
        voice.focus = { [weak self] in self?.panels?.focusComment() }
        voice.requestClose = { [weak self] in self?.cancelComment() }
        voice.reportError = { [weak self] in self?.error = $0 }
        if demo { Demo.populate(self); return }
        bridge.onEvent = { [weak self] event, value in self?.event(event, value) }
        do {
            let executable = Bundle.main.resourceURL!.appendingPathComponent("annotator-core")
            var environment = ProcessInfo.processInfo.environment
            environment["ANNOTATOR_HOST_PID"] = String(getpid())
            try bridge.start(executable: executable, environment: environment)
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
        if demo { return .null }
        return try await bridge.request(command, .object(args))
    }
    func act(_ command: String, _ args: [String: JSON] = [:]) {
        Task { do { _ = try await call(command, args) } catch { self.error = error.localizedDescription } }
    }
    func navigate(_ page: String, id: String? = nil) {
        self.page = page; search = ""; searching = false
        if let id { selected = id }
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
        case "bridge-error": error = value.string
        case "hide-menu": panels?.menu?.orderOut(nil)
        case "comment-opened": voice.cancel(); target = value; comment = ""; commentError = value["captureError"] == .null ? nil : value["captureError"].string
        case "show-comment": panels?.showComment(value)
        case "hide-comment": panels?.hideComment()
        case "comment-cancel": cancelDictation()
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
    func cancelComment() { cancelDictation(); act("cancel_comment") }
    func startDictation() { voice.start() }
    func finishDictation() async throws { try await voice.finish() }
    func submit(moving: Bool = false) async {
        guard !commentBusy else { return }; commentBusy = true; defer { commentBusy = false }
        do {
            try await finishDictation()
            if moving { _ = try await call("comment_finish_done", ["submit": .bool(!comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), "text": .string(comment), "keep": .bool(false)]) }
            else { _ = try await call("submit_comment", ["text": .string(comment)]) }
        } catch is CancellationError {
            return
        } catch {
            commentError = error.localizedDescription
            if moving { act("comment_finish_done", ["submit": .bool(false), "text": .string(comment), "keep": .bool(true)]) }
        }
    }
}
