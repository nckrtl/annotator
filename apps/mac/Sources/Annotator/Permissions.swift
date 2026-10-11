import Inject
import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
enum Permissions {
    static var accessibility: Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static var allGranted: Bool { accessibility && screenRecording }

    static func requestAccessibility() {
        // Adds Annotator to the list in Settings, so the user only has to flip the switch.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func open(_ url: String) {
        NSWorkspace.shared.open(URL(string: url)!)
    }
}

/// Shows which permissions are missing and how to grant them.
struct OnboardingView: View {
    @ObserveInjection var injection
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    let close: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 16) {
                Text("Annotator needs two permissions").font(.title2.bold())
                row(
                    granted: accessibility, title: "Accessibility",
                    reason: "Finds the element under the cursor.",
                    action: ("Open Settings", Permissions.requestAccessibility))
                row(
                    granted: screenRecording, title: "Screen Recording",
                    reason: "Captures a screenshot of what you annotate.",
                    action: ("Grant", Permissions.requestScreenRecording))
                Text("After you grant Screen Recording, macOS may need you to relaunch Annotator.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Relaunch Annotator", action: Permissions.relaunch)
                    Spacer()
                    Button(accessibility && screenRecording ? "Done" : "Close", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 460)
            .onReceive(timer) { _ in
                accessibility = Permissions.accessibility
                screenRecording = Permissions.screenRecording
            }
        }
        .enableInjection()
    }

    private func row(granted: Bool, title: String, reason: String, action: (String, () -> Void)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(granted ? "Granted." : "Missing. " + reason).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(action.0, action: action.1) }
        }
    }
}
