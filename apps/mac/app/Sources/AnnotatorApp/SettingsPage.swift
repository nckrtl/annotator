import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

struct SettingsPage: View {
    @Bindable var model: AppModel
    @State private var saved = false
    @State private var recorder = ShortcutRecorder()
    @State private var section = "general"
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if section == "general" {
                    KitGroup("Annotation server", footer: "The server keeps the shared queue. An unreachable server does not discard comments; Annotator keeps them for retry.") {
                        KitRow("Server URL") { KitTextField("http://127.0.0.1:29703/annotations", text: text("serverURL")).frame(width: 290) }
                        KitRow("Start the local server on launch") { KitSwitch("Start the local server", isOn: toggle("serverAutoStart")) }
                        KitRow("Local server", detail: model.state["localServer"]["error"].string.nilIfEmpty) {
                            if model.state["localServer"] == .null { KitValue("Remote") }
                            else { Button(model.state["localServer"]["running"].bool ? "Stop" : "Start") { model.act("server_control", ["action": .string(model.state["localServer"]["running"].bool ? "stop" : "start")]) }.buttonStyle(.kit).disabled(model.state["localServer"]["busy"].bool) }
                        }
                    }
                    KitGroup("Server tools") {
                        KitRow("Restart the local server") { Button("Restart") { model.act("server_control", ["action": .string("restart")]) }.buttonStyle(.kit).disabled(model.state["localServer"] == .null || model.state["localServer"]["busy"].bool) }
                        KitRow("Server URL") { Button("Open in browser") { model.act("open_server") }.buttonStyle(.kit) }
                    }
                    KitGroup("Capture", footer: "Press the shortcut to select an element. Hold Option and drag to select a region. Escape cancels.") {
                        KitRow("Global shortcut", detail: model.state["hotkeyError"].string.nilIfEmpty) {
                            Button(recorder.recording ? "Press a shortcut…" : model.state["hotkey"]["display"].string) { startRecording() }.buttonStyle(.kit)
                        }
                        KitRow("Permissions", detail: "Accessibility and Screen Recording") { Button("Review…") { model.panels?.permissions() }.buttonStyle(.kit) }
                    }
                    KitGroup("Delivery") {
                        KitRow("Waiting to send") { KitValue("\(model.state["pending"]["count"].int)") }
                        KitRow("Retry saved comments") { Button("Retry now") { model.act("retry_now") }.buttonStyle(.kit) }
                        KitRow("Refused comments") { Button("Show \(model.state["failedCount"].int) files") { model.act("show_failed") }.buttonStyle(.kit) }
                        KitRow("Server log") { Button("Open") { model.act("show_server_log") }.buttonStyle(.kit) }
                    }
                } else {
                    KitGroup("Operator", footer: "Operator pastes into the focused comment field. Annotator waits for the paste before it submits.") {
                        KitRow("Use Operator dictation") { KitSwitch("Use Operator", isOn: toggle("operatorEnabled")) }
                        KitRow("Start dictation with each comment") { KitSwitch("Start dictation automatically", isOn: toggle("operatorAutoStart")) }
                    }
                }
            }.frame(maxWidth: Kit.readableWidth).padding(Kit.columnMargin).padding(.bottom, 28).frame(maxWidth: .infinity)
        }.kitBottomFade().kitTopBar {
            PageBar(title: "Settings") {
                KitToolbarGroup {
                    KitToolbarPicker(selection: $section, options: [("general", "General"), ("dictation", "Dictation")])
                    KitToolbarButton(saved ? "Saved" : "Save") { Task { await model.saveSettings(); saved = model.error == nil; try? await Task.sleep(for: .seconds(1.6)); saved = false } }
                }
            }
        }
        .onDisappear { recorder.stop() }
        .onChange(of: section) { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .demoSettingsSection)) { section = $0.object as? String ?? "general" }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { model.settings[key].string }, set: { model.settings[key] = .string($0) }) }
    private func toggle(_ key: String) -> Binding<Bool> { Binding(get: { model.settings[key].bool }, set: { model.settings[key] = .bool($0) }) }
    private func startRecording() {
        if recorder.recording { recorder.stop(); return }
        recorder.start(changed: { recording in
            model.act("hotkey_recording", ["recording": .bool(recording)])
        }, selected: { keyCode, modifiers in
            model.settings["hotkey"] = .object(["keyCode": .number(Double(keyCode)), "modifiers": .number(Double(modifiers))])
            Task { await model.saveSettings() }
        })
    }
}
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
extension Notification.Name { static let demoSettingsSection = Notification.Name("demo-settings-section") }
