import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

@MainActor final class Panels {
    unowned let model: AppModel
    var menu: NSWindow?
    var commentPanel: NSPanel?
    var permissionWindow: NSWindow?
    init(model: AppModel) { self.model = model }
    func permissions() {
        menu?.orderOut(nil)
        if let permissionWindow { permissionWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 390), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Annotator permissions"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true; window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PermissionsView(model: model).kitAppearance().ignoresSafeArea())
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(); permissionWindow = window
    }
    private var commentGeneration = 0
    func hideComment() { commentGeneration += 1; commentPanel?.orderOut(nil) }
    func showComment(_ frame: JSON) {
        let panel = commentPanel ?? makeComment()
        commentGeneration += 1; let generation = commentGeneration
        func rect(_ value: NSRect) -> JSON { .object(["x": .number(value.minX), "y": .number(value.minY), "width": .number(value.width), "height": .number(value.height)]) }
        let screens = NSScreen.screens.map { JSON.object(["frame": rect($0.frame), "visible": rect($0.visibleFrame)]) }
        let mouse = NSEvent.mouseLocation
        Task {
            do {
                let origin = try await model.call("comment_origin", ["target": frame, "screens": .array(screens), "mouse": .array([.number(mouse.x), .number(mouse.y)]), "size": .array([.number(panel.frame.width), .number(panel.frame.height)])])
                guard generation == commentGeneration else { return }
                guard origin.array.count == 2 else { throw BridgeError("The comment panel could not be placed.") }
                panel.setFrameOrigin(NSPoint(x: origin.array[0].double, y: origin.array[1].double))
                panel.makeKeyAndOrderFront(nil); NSApp.activate()
                NotificationCenter.default.post(name: .focusComment, object: nil)
                if model.target["dictation"]["autoStart"].bool && !model.demo {
                    try? await Task.sleep(for: .milliseconds(200))
                    if generation == commentGeneration { model.startDictation() }
                }
            } catch { model.error = error.localizedDescription; model.act("cancel_comment") }
        }
    }

    private func makeComment() -> NSPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CommentView(model: model).kitAppearance())
        commentPanel = panel; return panel
    }
    func focusComment() { commentPanel?.makeKeyAndOrderFront(nil); NSApp.activate(); NotificationCenter.default.post(name: .focusComment, object: nil) }
}
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
extension Notification.Name { static let focusComment = Notification.Name("focus-comment") }

struct CommentView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AnnotatorMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Annotate").font(.kitTitle)
                    Text(model.target["label"].string).font(.kitDetail).foregroundStyle(.secondary).lineLimit(1).help(model.target["label"].string)
                }
                Spacer()
                KitIconButton(.close, help: "Cancel comment") { model.cancelComment() }.keyboardShortcut(.cancelAction)
            }
            if model.target["mode"].string == "window" { Text("Window selection · no accessible element found").font(.kitDetail).foregroundStyle(.secondary) }
            CommentEditor(text: $model.comment, submit: { Task { await model.submit() } }, cancel: { model.cancelComment() })
                .padding(8).background(Color.kitSurface, in: RoundedRectangle(cornerRadius: Kit.Radius.row))
                .overlay(RoundedRectangle(cornerRadius: Kit.Radius.row).strokeBorder(Color.kitSeparator, lineWidth: 0.5))
                .accessibilityLabel("Comment")
            if let error = model.voice.error ?? model.commentError { KitGroup { KitNotice(error, tone: .error) } }
            Text("↩ submits · ⇧↩ adds a line · Esc cancels").font(.kitDetail).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if model.target["dictation"] != .null {
                    KitIconButton(.microphone, help: model.dictation == "recording" ? "Stop dictation" : "Dictate comment", spinning: model.dictation == "transcribing") {
                        focused = true
                        if model.dictation == "recording" { Task { do { try await model.finishDictation() } catch { model.commentError = error.localizedDescription } } }
                        else { model.startDictation() }
                    }.disabled(model.commentBusy || ["starting", "transcribing"].contains(model.dictation))
                    Text(model.dictation == "idle" ? "Dictate" : model.dictation.capitalized + "…").font(.kitDetail).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Submit") { Task { await model.submit() } }.buttonStyle(.kitPrimary).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.commentBusy || (model.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.dictation == "idle"))
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.kitContent)
            .clipShape(RoundedRectangle(cornerRadius: Kit.windowRadius))
            .overlay(RoundedRectangle(cornerRadius: Kit.windowRadius).strokeBorder(Color.kitSeparator, lineWidth: 0.5))
            .onAppear { focused = true }.onReceive(NotificationCenter.default.publisher(for: .focusComment)) { _ in focused = true }
    }
}
struct PermissionsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) { AnnotatorMark(); Text("Annotate anything on screen").font(.kitHeading); Text("Allow two permissions to select and capture UI.").font(.kitDetail).foregroundStyle(.secondary) }
            KitGroup {
                permission("Accessibility", "Read the element under your cursor.", "accessibility")
                permission("Screen Recording", "Capture the area you annotate.", "screenRecording")
            }
            Text("After granting Screen Recording, quit and reopen Annotator if macOS asks.").font(.kitDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Check again") { Task { do { model.state["permissions"] = try await model.call("get_permissions") } catch { model.error = error.localizedDescription } } }.buttonStyle(.kitSecondary)
                Button(model.state["permissions"]["accessibility"].bool && model.state["permissions"]["screenRecording"].bool ? "Done" : "Relaunch") {
                    if model.state["permissions"]["accessibility"].bool && model.state["permissions"]["screenRecording"].bool { model.panels?.permissionWindow?.close() } else { model.act("relaunch") }
                }.buttonStyle(.kitPrimary)
            }
        }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 20).frame(maxWidth: .infinity, maxHeight: .infinity).kitFrosted()
            .task {
                guard !model.demo else { return }
                while !Task.isCancelled {
                    if let value = try? await model.call("get_permissions") { model.state["permissions"] = value }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
    private func permission(_ title: String, _ detail: String, _ kind: String) -> some View {
        KitRow(title, detail: detail) {
            if model.state["permissions"][kind].bool { KitIconImage(.done, size: 18).accessibilityLabel("Allowed") }
            else { Button("Allow") { model.act("request_permission", ["kind": .string(kind)]) }.buttonStyle(.kit) }
        }
    }
}
struct MenuPanel: View {
    @Bindable var model: AppModel
    @State private var contentHeight: CGFloat = 560
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) { AnnotatorMark(size: 28); VStack(alignment: .leading, spacing: 2) { Text("Annotator").font(.kitTitle); Text(model.state["health"]["title"].string).font(.kitDetail).foregroundStyle(.secondary) }; Spacer(); KitIconButton(.settings, help: "Settings") { model.navigate("settings") }.accessibilityLabel("Settings") }
                Button { model.act("toggle_annotating") } label: { HStack { Text(model.state["annotating"].bool ? "Stop annotating" : "Annotate screen"); Spacer(); KitKeyCap(model.state["hotkey"]["display"].string) } }.buttonStyle(.kitPrimary)
                if model.state["health"]["tone"].string == "error" { KitGroup { KitNotice(model.state["health"]["title"].string, tone: .error) } }
                KitGroup("Recent annotations") {
                    if model.items.isEmpty { KitRow("No annotations yet") { EmptyView() } }
                    ForEach(Array(model.items.sorted { $0["number"].int > $1["number"].int }.prefix(5)), id: \.self) { item in
                        Button { model.navigate("all", id: item["id"].string) } label: { AnnotationRow(item: item).padding(12) }.buttonStyle(.plain)
                    }
                    KitActionRow("Open library", icon: .allItems) { model.navigate("all") }
                }
                if model.state["pending"]["count"].int > 0 {
                    KitGroup { KitNotice("\(model.state["pending"]["count"].int) comments are waiting to send.", tone: .warning) { Button("Retry") { model.act("retry_now") }.buttonStyle(.kit) } }
                }
                if model.state["failedCount"].int > 0 { Button("Show \(model.state["failedCount"].int) refused comments") { model.act("show_failed") }.buttonStyle(.kit) }
                HStack {
                    Button("Projects") { model.navigate("projects") }.buttonStyle(.kitSecondary)
                    Spacer()
                    Menu { Button("Open server") { model.act("open_server") }; Button("Permissions…") { model.panels?.permissions() }; Button("Copy agent prompt") { model.act("copy_prompt", ["scope": .string("all")]) }; Divider(); Button("Quit Annotator") { NSApp.terminate(nil) } } label: { KitIconImage(.more, size: 14).foregroundStyle(.secondary).frame(width: 30, height: 28).contentShape(Rectangle()) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("More actions")
                }
            }.padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // A ScrollView has no intrinsic height. A maximum alone collapses MenuBarExtra
        // to a strip; give its host a measured height and scroll only when needed.
        .frame(width: 360, height: min(contentHeight, min(620, (NSScreen.main?.visibleFrame.height ?? 700) - 24)))
        .background(Color.kitContent).background(WindowReader { model.panels?.menu = $0 })
    }
}
