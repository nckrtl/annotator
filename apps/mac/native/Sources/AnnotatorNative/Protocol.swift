import AnnotatorNativeCore
import AppKit
import ApplicationServices
import os

// The JSON-lines protocol with Annotator (docs/port.md §1).
// Commands arrive on stdin as {"action": …}; events go to stdout as {"type": …}.

let log = Logger(subsystem: "com.nckrtl.annotator.native", category: "helper")

/// The capture helper, Rust core and SwiftUI host. Hit tests and captures skip all three.
var ourPids: Set<pid_t> {
    var pids: Set<pid_t> = [getpid(), getppid()]
    if let host = ProcessInfo.processInfo.environment["ANNOTATOR_HOST_PID"].flatMap(Int32.init) { pids.insert(host) }
    return pids
}

private let output = NSLock()

/// Writes one event as one line. The lock keeps lines whole, even a record of several MB.
func emit(_ event: [String: Any]) {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes])
    } catch {
        log.error("Could not encode an event: \(error.localizedDescription, privacy: .public)")
        return
    }
    output.lock()
    defer { output.unlock() }
    // Throws instead of raising when Annotator closed the pipe; then the parent watch exits us.
    try? FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
}

func emitError(_ message: String) {
    emit(["type": "error", "message": message])
}

enum Permissions {
    static var accessibility: Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static var event: [String: Any] {
        ["type": "permissions", "accessibility": accessibility, "screenRecording": screenRecording]
    }

    static func requestAccessibility() {
        // Adds the app to the list in Settings, so the user only has to flip the switch.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}

/// Runs the overlay and answers commands. Replaces AppController's in-process wiring.
@MainActor
final class Helper {
    private let reader = AXReader()
    private lazy var overlay = OverlayController(reader: reader)

    init() {
        overlay.onSelect = { [weak self] target in self?.select(target) }
        overlay.onEscape = { [weak self] in self?.overlay.hide(reason: "escape"); emit(["type": "escape"]) }
    }

    func receive(_ line: String) {
        guard let command = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            emitError("Not a JSON command: \(line.prefix(200))")
            return
        }
        switch command["action"] as? String {
        case "ping":
            emit(["type": "online"])
        case "permissions":
            emit(Permissions.event)
        case "requestScreenCapture":
            Permissions.requestScreenRecording()
            emit(Permissions.event)
        case "requestAccessibility":
            Permissions.requestAccessibility()
            emit(Permissions.event)
        case "annotate":
            guard let on = command["on"] as? Bool else { return emitError("annotate needs a boolean \"on\".") }
            on ? overlay.show() : overlay.hide()
        case let action:
            emitError("Unknown action: \(action ?? "none")")
        }
    }

    /// The overlay was released after selecting `target`. Capture before Annotator shows the panel,
    /// so the image shows what the user clicked; then send the record.
    private func select(_ target: Target) {
        let generation = overlay.generation
        Task {
            var capture: Capture.Result?
            var captureError: String?
            do {
                capture = try await Capture.capture(target.frame)
            } catch {
                captureError = "\(error)"
            }
            guard generation == overlay.generation else { return }
            let annotation = Annotation(
                comment: "", target: target, screenSize: capture?.screenSize ?? .zero,
                screenshot: capture?.dataURL, project: nil)
            let record: Any
            do {
                record = try JSONSerialization.jsonObject(with: annotation.encoded())
            } catch {
                emitError("Could not encode the annotation: \(error.localizedDescription)")
                overlay.hide(reason: "encoding-failed")
                return
            }
            emit([
                "type": "selected",
                "record": record,
                "label": target.overlayLabel,
                "mode": target.mode.rawValue,
                "frame": [
                    "x": target.frame.minX, "y": target.frame.minY,
                    "width": target.frame.width, "height": target.frame.height,
                ],
                "captureError": captureError ?? NSNull(),
            ])
        }
    }
}

/// Fixed reasons only; no target, transcript, token or response data.
func logOverlayRelease(_ reason: String) {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.nckrtl.annotator")
    let file = directory.appendingPathComponent("overlay.log")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256_000 {
        try? FileManager.default.removeItem(at: file)
    }
    if !FileManager.default.fileExists(atPath: file.path) {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Date().ISO8601Format()) overlay-release \(reason)\n".utf8))
    }
}
