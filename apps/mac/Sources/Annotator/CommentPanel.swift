import Inject
import AnnotatorCore
import AppKit
import OSLog
import SwiftUI

let log = Logger(subsystem: "com.nckrtl.annotator", category: "app")

@MainActor @Observable
final class CommentModel {
    enum Dictation: Equatable {
        case off
        case checking
        case unavailable(String)
        case idle
        case recording
        case transcribing
    }

    let target: Target
    var capture: Capture.Result?
    var captureError: String?
    var text = ""
    var dictation = Dictation.off
    var dictationMessage: String?
    /// Set once the comment is handed to the server, so it is never posted twice.
    var posted = false

    init(target: Target) {
        self.target = target
    }

    var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CommentView: View {
    @ObserveInjection var injection
    @Bindable var model: CommentModel
    let submit: () -> Void
    let cancel: () -> Void
    let toggleDictation: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.target.overlayLabel)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if model.target.mode == .window {
                    notice("No element found here. This annotates the whole window.", color: .orange)
                }
                if let error = model.captureError {
                    notice("No screenshot: \(error)", color: .red)
                }
                TextEditor(text: $model.text)
                    .font(.body)
                    .focused($focused)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                status
                HStack(spacing: 8) {
                    dictationControl
                    Spacer()
                    Button("Cancel", action: cancel)
                        .help("Cancel this annotation and dictation.")
                    Button("Submit", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSubmit && model.dictation != .recording)
                        .help("↩")
                }
            }
            .padding(12)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .onAppear { focused = true }
        }
        .enableInjection()
    }

    @ViewBuilder private var status: some View {
        if model.dictation == .recording {
            Text("Listening. ↩ or a click on the next element stops and submits. Esc cancels the dictation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("↩ submits. ⇧↩ adds a line. Esc cancels.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var dictationControl: some View {
        switch model.dictation {
        case .off:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .unavailable(let message):
            Label(message, systemImage: "mic.slash").font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .recording, .transcribing:
            Button(action: toggleDictation) {
                Image(systemName: model.dictation == .recording ? "stop.circle.fill" : "mic")
                    .foregroundStyle(model.dictation == .recording ? .red : .primary)
            }
            .focusable(false)
            .disabled(model.dictation == .transcribing)
            .help(model.dictation == .recording ? "Stop dictation and paste" : "Dictate with Ofide")
            if model.dictation == .transcribing {
                Text("Transcribing…").font(.caption)
            } else if model.dictation == .recording {
                Text("Recording…").font(.caption).foregroundStyle(.red)
            } else if let message = model.dictationMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

/// A borderless panel that can become key, so typing and Ofide's paste land in the comment field.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CommentPanelController {
    let model: CommentModel
    private let panel: KeyPanel
    private var keyMonitor: Any?
    var onSubmit: ((CommentModel) -> Void)?
    var onClose: (() -> Void)?
    /// Set when dictation is on. A failure explains why Ofide cannot be used.
    var ofide: Result<OfideClient, OfideSetupError>?

    init(model: CommentModel) {
        self.model = model
        panel = KeyPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show() {
        let view = CommentView(
            model: model,
            submit: { [weak self] in self?.submit() },
            cancel: { [weak self] in self?.close() },
            toggleDictation: { [weak self] in self?.toggleDictation() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        position()

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 {  // Esc
                self.close()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {  // Return, Enter
                // ⇧↩ inserts a new line. A Return that confirms an input method's composition stays with it.
                if event.modifierFlags.contains(.shift) { return event }
                if let text = self.panel.firstResponder as? NSTextView, text.hasMarkedText() { return event }
                self.submit()
                return nil
            }
            return event
        }
        checkOfide()
    }

    /// Hide immediately. Cancel Ofide separately; cancellation never requests a paste.
    func close() {
        guard !closing else { return }
        closing = true
        if (model.dictation == .recording || model.dictation == .transcribing),
            case .success(let ofide) = ofide {
            let previous = Self.ofideCommand
            Self.ofideCommand = Task {
                // A start already in flight must finish before we cancel it.
                let started = await previous?.value
                guard started != .noDictation else { return .ok }
                let result = await ofide.cancel()
                if result != .ok && result != .noDictation {
                    let alert = NSAlert()
                    alert.messageText = "Could not cancel Ofide"
                    alert.informativeText = result.message ?? "Cancel the recording in Ofide."
                    alert.runModal()
                }
                return result
            }
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.dictation = .off
        panel.orderOut(nil)
        onClose?()
        onClose = nil
    }

    // New panels wait for the previous cancellation, so a late cancel cannot stop a new recording.
    private static var ofideCommand: Task<OfideResult, Never>?
    private var recordingStartedAt: Double = 0

    private var closing = false

    /// Below the target if there is room, otherwise above, then clamped to the screen.
    private func position() {
        let target = Geometry.appKit(fromTopLeft: model.target.frame, mainScreenHeight: NSScreen.mainHeight)
        let center = CGPoint(x: target.midX, y: target.midY)
        let screen = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0])
            .visibleFrame
        let size = panel.frame.size
        var origin = CGPoint(x: target.minX, y: target.minY - size.height - 8)
        if origin.y < screen.minY { origin.y = target.maxY + 8 }
        if origin.y + size.height > screen.maxY {
            // The target fills the screen height: put the panel inside it, near the cursor.
            origin.y = min(max(NSEvent.mouseLocation.y - size.height - 16, screen.minY), screen.maxY - size.height)
            origin.x = NSEvent.mouseLocation.x + 16
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// ↩ or Submit. While recording, stop first and submit once the paste lands. Submits at most once.
    private func submit() {
        guard !submitted else { return }
        submitted = true
        Task {
            guard await finishDictation(), !closing, model.canSubmit else {
                submitted = false
                return
            }
            onSubmit?(model)
        }
    }

    private var submitted = false

    func resize() {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    // MARK: - Dictation

    /// Start dictating as soon as the panel opens, like the web annotator.
    var autoStart = false

    private func checkOfide() {
        switch ofide {
        case nil:
            return
        case .failure(let error):
            model.dictation = .unavailable(error.message)
            resize()
        case .success(let client):
            model.dictation = .checking
            Task {
                let result = await client.status()
                guard model.dictation == .checking else { return }
                model.dictation = result == .ok ? .idle : .unavailable(result.message ?? "Ofide is not available.")
                resize()
                if result == .ok, autoStart { startRecording() }
            }
        }
    }

    /// After a failed call: lose the button when Ofide itself is unusable, keep it otherwise.
    private func settle(_ result: OfideResult) -> CommentModel.Dictation {
        switch result {
        case .notRunning, .unauthorized: .unavailable(result.message ?? "")
        default: .idle
        }
    }

    private func toggleDictation() {
        switch model.dictation {
        case .idle: startRecording()
        case .recording: Task { await finishDictation() }
        default: break
        }
    }

    /// The comment text when the recording started. A paste shows up as a change from it.
    private var textBeforeRecording = ""
    /// Set while we stop the recording ourselves, so the watcher does not handle the same stop.
    private var stopping = false

    private func startRecording() {
        guard !closing, case .success(let ofide) = ofide, model.dictation == .idle else { return }
        model.dictationMessage = nil
        model.dictation = .recording
        textBeforeRecording = model.text
        resize()
        let previous = Self.ofideCommand
        let start = Task { [self] in
            _ = await previous?.value
            guard !closing else { return OfideResult.noDictation }
            recordingStartedAt = Date().timeIntervalSince1970 * 1000
            logFocus("before start")
            return await ofide.start()
        }
        Self.ofideCommand = start
        Task {
            let result = await start.value
            guard !closing else { return }
            log.info("dictate/start: \(String(describing: result), privacy: .public)")
            guard result == .ok else {
                model.dictation = settle(result)
                model.dictationMessage = result.message
                resize()
                return
            }
            await watch(ofide)
        }
    }

    /// Follows Ofide while it records. Ofide can end the recording itself (its hotkey or pause detection);
    /// then it transcribes and pastes, and we wait for the text.
    private func watch(_ ofide: OfideClient) async {
        while model.dictation == .recording, !stopping {
            let snapshot = await ofide.snapshot()
            guard !closing, model.dictation == .recording, !stopping else { return }
            if let cancelledAt = snapshot?.cancelledAt, cancelledAt >= recordingStartedAt {
                model.dictation = .off
                close()
                return
            }
            let state = snapshot?.status
            switch state {
            case "loading", "arming", "recording":
                try? await Task.sleep(for: .milliseconds(100))
                continue
            case nil:
                model.dictation = .unavailable("Ofide stopped answering.")
                resize()
                return
            default:
                break
            }
            // Ofide ended the recording on its own.
            log.info("Ofide ended the recording itself: \(state ?? "nil", privacy: .public)")
            model.dictation = .transcribing
            resize()
            var current = state
            let deadline = Date().addingTimeInterval(120)
            while !closing, current == "transcribing", Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                current = await ofide.state()
            }
            guard !closing else { return }
            if await waitForPaste() {
                guard !closing else { return }
                model.dictation = .idle
            } else {
                guard !closing else { return }
                model.dictation = .idle
                model.dictationMessage = "Ofide finished without text. It was cancelled or heard only silence."
            }
            resize()
            return
        }
    }

    /// Waits up to 3 s for the comment to change from `textBeforeRecording`, then for it to settle.
    private func waitForPaste() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !closing, model.text == textBeforeRecording, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !closing, model.text != textBeforeRecording else { return false }
        var last = model.text
        repeat {
            last = model.text
            try? await Task.sleep(for: .milliseconds(250))
        } while !closing && model.text != last
        return !closing
    }

    private func logFocus(_ moment: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        log.info("\(moment, privacy: .public): active=\(NSApp.isActive) frontmost=\(front, privacy: .public) key=\(self.panel.isKeyWindow) responder=\(responder, privacy: .public)")
    }

    /// Stops a running dictation and waits until Ofide's paste lands in the comment field.
    /// Returns true when there is no dictation or the paste arrived; false shows why in the panel.
    @discardableResult
    func finishDictation() async -> Bool {
        guard !closing else { return false }
        _ = await Self.ofideCommand?.value
        guard !closing else { return false }
        // Ofide is already transcribing on its own: wait for the watcher to finish.
        while !closing, model.dictation == .transcribing, !stopping { try? await Task.sleep(for: .milliseconds(100)) }
        guard !closing else { return false }
        guard model.dictation == .recording, case .success(let ofide) = ofide else {
            return model.dictationMessage == nil || model.text != textBeforeRecording
        }
        stopping = true
        defer { stopping = false }
        model.dictation = .transcribing
        model.dictationMessage = nil
        resize()
        // Ofide pastes into the focused field of the frontmost app: keep that us.
        NSApp.activate()
        panel.makeKey()

        logFocus("before stop")
        let result = await ofide.stop()
        log.info("dictate-stop: \(String(describing: result), privacy: .public)")
        guard !closing else { return false }
        guard result == .ok else {
            model.dictation = settle(result)
            model.dictationMessage = result == .noDictation
                ? "Ofide had no active recording. It may have been cancelled."
                : result.message
            resize()
            return false
        }
        let pasted = await waitForPaste()
        model.dictation = .idle
        if !pasted { model.dictationMessage = "Ofide sent a paste, but no text reached the comment field." }
        resize()
        return pasted
    }
}
