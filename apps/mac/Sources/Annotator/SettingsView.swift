import Inject
import AnnotatorCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObserveInjection var injection
    @Bindable var settings: Settings
    let serverState: LocalServerState
    let startServer: () -> Void
    let stopServer: () -> Void
    let restartServer: () -> Void
    let showServerLog: () -> Void
    /// Pauses the global hotkey while a new one is recorded.
    let recording: (Bool) -> Void

    @State private var t3EndpointDraft = ""
    @State private var t3TokenDraft = ""
    @State private var t3ConnectionMessage: String?
    @State private var serverDraft = ""
    @State private var ofideDraft = ""
    @State private var recorder: Any?

    var body: some View {
        Group {
            Form {
                Section("Annotation server") {
                    Toggle("Start local server when Annotator opens", isOn: $settings.serverAutoStart)
                    if let url = settings.server, let local = LocalServer(url: url) {
                        HStack {
                            Button(serverState.running ? "Stop Server" : "Start Server", action: serverState.running ? stopServer : startServer)
                            if serverState.running { Button("Restart Server", action: restartServer) }
                            Button("View Logs", action: showServerLog)
                                .disabled(!FileManager.default.fileExists(atPath: local.log.path))
                            if serverState.busy { ProgressView().controlSize(.small) }
                        }
                        .disabled(serverState.busy || serverDraft != settings.serverURL)
                        if let error = serverState.error {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    Text("The server keeps running when Annotator quits. Save a changed URL before using the controls.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("URL", text: $serverDraft, prompt: Text(Settings.defaultServerURL))
                        .onSubmit { apply() }
                    if Settings.validURL(serverDraft) == nil {
                        Text("Enter an http or https URL.").font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Shortcut") {
                    HStack {
                        Text("Toggle annotate mode")
                        Spacer()
                        Button(recorder == nil ? settings.hotkey.display : "Press a shortcut…") {
                            recorder == nil ? startRecording() : stopRecording()
                        }
                    }
                    if let hotkeyError = settings.hotkeyError {
                        Text(hotkeyError).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Dictation") {
                    Toggle("Enable Ofide dictation", isOn: $settings.ofideEnabled)
                    Toggle("Start dictating when the comment panel opens", isOn: $settings.ofideAutoStart)
                        .disabled(!settings.ofideEnabled)
                    Picker("App", selection: $settings.ofideApp) {
                        ForEach(Settings.OfideApp.allCases) { Text($0.name).tag($0) }
                    }
                    .disabled(!settings.ofideEnabled)
                    .onChange(of: settings.ofideApp) { _, app in
                        ofideDraft = app.defaultURL
                        settings.ofideURL = app.defaultURL
                    }
                    TextField("URL", text: $ofideDraft, prompt: Text(settings.ofideApp.defaultURL))
                        .disabled(!settings.ofideEnabled)
                        .onSubmit { apply() }
                    Text("Annotator reads the Local API token from the app's control.json.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.ofideEnabled && Settings.validURL(ofideDraft) == nil {
                        Text("Enter an http or https URL.").font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Conn") {
                    Toggle("Start agent sessions in Conn", isOn: $settings.t3Enabled)
                    TextField("Server endpoint", text: $t3EndpointDraft, prompt: Text("http://127.0.0.1:3780"))
                    SecureField("Access token", text: $t3TokenDraft, prompt: Text("Leave blank to keep the saved token"))
                    Button("Save Connection") {
                        guard let url = Settings.validURL(t3EndpointDraft), url.user == nil, url.password == nil,
                              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
                            t3ConnectionMessage = "Enter an http or https server origin without a path."
                            return
                        }
                        let endpoint = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
                        do {
                            if !t3TokenDraft.isEmpty { try Keychain.save(t3TokenDraft, account: endpoint) }
                            settings.t3Endpoint = endpoint
                            t3EndpointDraft = endpoint
                            t3TokenDraft = ""
                            t3ConnectionMessage = "Connection saved."
                        } catch { t3ConnectionMessage = error.localizedDescription }
                    }
                    if let t3ConnectionMessage { Text(t3ConnectionMessage).font(.caption) }
                    Text("Set up and run Conn yourself. On that server, use: t3 auth session issue --token-only --label annotator --ttl 30d --base-dir <your Conn data folder>. Paste the token here; it is stored in Keychain.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Pairing links are created on the Conn server with t3 pair. They connect a Conn window and are separate from Annotator’s access token.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Local Conn window (optional)") {
                        TextField("Server data folder", text: $settings.t3Home)
                        TextField("Window data folder", text: $settings.t3WindowHome)
                        Text("Used only by Open Session and Copy Pairing URL for a server on this Mac.").font(.caption)
                    }
                    TextField("Default model", text: $settings.t3DefaultModel, prompt: Text("claudeAgent/claude-opus-5-5"))
                        .disabled(!settings.t3Enabled)
                    if !settings.t3DefaultModel.isEmpty, T3ModelSelection(settings.t3DefaultModel) == nil {
                        Text("Write it as provider/model, such as claudeAgent/claude-opus-5-5.").font(.caption).foregroundStyle(.red)
                    }
                    Picker("Effort", selection: $settings.t3Effort) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Max").tag("max")
                    }
                    Toggle("Send new annotations to an idle session", isOn: $settings.t3Nudge)
                        .disabled(!settings.t3Enabled)
                }
                HStack {
                    Spacer()
                    Button("Save", action: apply).keyboardShortcut(.defaultAction)
                }
            }
            .formStyle(.grouped)
            .frame(width: 460)
            .onAppear {
                t3EndpointDraft = settings.t3Endpoint
                serverDraft = settings.serverURL
                ofideDraft = settings.ofideURL
            }
            .onDisappear { stopRecording() }
        }
        .enableInjection()
    }

    private func apply() {
        if Settings.validURL(serverDraft) != nil, serverDraft != settings.serverURL { settings.serverURL = serverDraft }
        if Settings.validURL(ofideDraft) != nil, ofideDraft != settings.ofideURL { settings.ofideURL = ofideDraft }
    }

    private func startRecording() {
        recording(true)
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc cancels.
                stopRecording()
                return nil
            }
            var modifiers: Hotkey.Modifiers = []
            let flags = event.modifierFlags
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
            let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
            guard hotkey.isValid else { return nil }
            settings.hotkey = hotkey
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        NSEvent.removeMonitor(recorder)
        self.recorder = nil
        recording(false)
    }
}
