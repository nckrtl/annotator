import AppKit
import SwiftUI
import AnnotatorCore

@MainActor @Observable final class AppModel {
    static let shared = AppModel()
    var state: JSON = .object([:]) {
        didSet {
            if isAnnotating && !(oldValue["annotating"].bool || oldValue["commentOpen"].bool) {
                hideLibraryForAnnotation()
            }
        }
    }
    var settings: JSON = .object([:])
    var projects: [JSON] = []
    var projectsError = ""
    var projectsSaving = false
    var selectedProjectID = ""
    var selectedProject: JSON? { projects.first { $0["id"].string == selectedProjectID } }
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
    var isAnnotating: Bool { state["annotating"].bool || state["commentOpen"].bool }
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
        voice.focus = { [weak self] in
            guard let panels = self?.panels else { throw CancellationError() }
            try await panels.prepareDictation()
        }
        voice.releaseOverlay = { [weak self] _ in self?.releaseOverlay() }
        voice.requestClose = { [weak self] in self?.cancelComment() }
        voice.reportError = { [weak self] in self?.commentError = $0 }
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
    /// Activation for the comment field must not also reveal the library.
    func hideLibraryForAnnotation() {
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
        case "comment-opened": hideLibraryForAnnotation(); voice.cancel(); target = value; comment = ""; commentError = value["captureError"] == .null ? nil : value["captureError"].string
        case "show-comment": panels?.showComment(value)
        case "hide-comment": panels?.hideComment()
        case "comment-cancel": cancelDictation(); panels?.hideComment()
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
    func submit() async {
        guard !commentBusy else { return }; commentBusy = true; defer { commentBusy = false }
        do {
            try await finishDictation()
            _ = try await call("submit_comment", ["text": .string(comment)])
        } catch is CancellationError {
            releaseOverlay(); return
        } catch {
            commentError = error.localizedDescription
        }
    }
}
