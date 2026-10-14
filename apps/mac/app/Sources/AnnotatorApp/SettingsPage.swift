import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

struct SettingsPage: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var saved = false
    @State private var recording = false
    @State private var monitor: Any?
    @State private var section = "general"
    @State private var connectionSaved = false
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
                            Button(recording ? "Press a shortcut…" : model.state["hotkey"]["display"].string) { startRecording() }.buttonStyle(.kit)
                        }
                        KitRow("Permissions", detail: "Accessibility and Screen Recording") { Button("Review…") { model.panels?.permissions() }.buttonStyle(.kit) }
                    }
                    KitGroup("Delivery") {
                        KitRow("Waiting to send") { KitValue("\(model.state["pending"]["count"].int)") }
                        KitRow("Retry saved comments") { Button("Retry now") { model.act("retry_now") }.buttonStyle(.kit) }
                        KitRow("Refused comments") { Button("Show \(model.state["failedCount"].int) files") { model.act("show_failed") }.buttonStyle(.kit) }
                        KitRow("Server log") { Button("Open") { model.act("show_server_log") }.buttonStyle(.kit) }
                    }
                } else if section == "dictation" {
                    KitGroup("Operator", footer: "Operator pastes into the focused comment field. Annotator waits for the paste before it submits.") {
                        KitRow("Use Operator dictation") { KitSwitch("Use Operator", isOn: toggle("operatorEnabled")) }
                        KitRow("Start dictation with each comment") { KitSwitch("Start dictation automatically", isOn: toggle("operatorAutoStart")) }

                    }
                } else {
                    KitGroup("Conn sessions", footer: "Create a session for each project. Automatic nudges send new annotations to the existing session only when enabled.") {
                        KitRow("Enable Conn") { KitSwitch("Enable Conn", isOn: toggle("t3Enabled")) }
                        KitRow("Nudge sessions automatically") { KitSwitch("Automatic nudges", isOn: toggle("t3Nudge")) }
                        KitRow("Server endpoint") { KitTextField("http://127.0.0.1:3780", text: text("t3Endpoint")).frame(width: 270) }
                        KitRow("Connection token") { KitTextField("Leave blank to keep saved token", text: $token, secure: true).frame(width: 270) }
                        KitRow("Save connection", detail: "The token is stored in Keychain.") { Button(connectionSaved ? "Saved" : "Save token") { Task {
                            do { _ = try await model.call("conn_save_connection", ["endpoint": model.settings["t3Endpoint"], "token": .string(token)]); token = ""; connectionSaved = true; try? await Task.sleep(for: .seconds(1.6)); connectionSaved = false }
                            catch { model.error = error.localizedDescription }
                        } }.buttonStyle(.kit) }
                        KitRow("Pair a Conn window") { Button("Copy pairing URL") { model.act("conn_pairing_url") }.buttonStyle(.kit) }
                    }
                    KitGroup("Session defaults") {
                        KitRow("Model") { KitTextField("provider/model", text: text("t3DefaultModel")).frame(width: 290) }
                        KitRow("Reasoning effort") { KitPicker(selection: text("t3Effort"), options: ["low", "medium", "high", "xhigh", "max"].map { ($0, $0.capitalized) }) }
                        KitRow("Server data folder") { KitTextField("~/.t3/headless", text: text("t3Home")).frame(width: 290) }
                        KitRow("Window data folder") { KitTextField("~/.t3/desktop-dev", text: text("t3WindowHome")).frame(width: 290) }
                    }
                }
            }.frame(maxWidth: Kit.readableWidth).padding(Kit.columnMargin).padding(.bottom, 28).frame(maxWidth: .infinity)
        }.kitBottomFade().kitTopBar {
            PageBar(title: "Settings") {
                KitToolbarGroup {
                    KitToolbarPicker(selection: $section, options: [("general", "General"), ("dictation", "Dictation"), ("conn", "Conn")])
                    KitToolbarButton(saved ? "Saved" : "Save") { Task { await model.saveSettings(); saved = model.error == nil; try? await Task.sleep(for: .seconds(1.6)); saved = false } }
                }
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: .demoSettingsSection)) { section = $0.object as? String ?? "general" }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { model.settings[key].string }, set: { model.settings[key] = .string($0) }) }
    private func toggle(_ key: String) -> Binding<Bool> { Binding(get: { model.settings[key].bool }, set: { model.settings[key] = .bool($0) }) }
    private func startRecording() {
        guard !recording else { stopRecording(); return }; recording = true
        model.act("hotkey_recording", ["recording": .bool(true)])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode != 53 {
                    let flags = event.modifierFlags
                    guard !flags.intersection([.command, .control, .option]).isEmpty else { return }
                    let modifiers = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
                    model.settings["hotkey"] = .object(["keyCode": .number(Double(event.keyCode)), "modifiers": .number(Double(modifiers))])
                    Task { await model.saveSettings() }
                }
                stopRecording()
            }
            return nil
        }
    }
    private func stopRecording() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; if recording { model.act("hotkey_recording", ["recording": .bool(false)]) }; recording = false }
}
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
extension Notification.Name { static let demoSettingsSection = Notification.Name("demo-settings-section") }
