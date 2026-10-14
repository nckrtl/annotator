import AppKit
import SwiftUI
import Testing
import AnnotatorCore
@testable import AnnotatorApp

/// Optional offscreen captures. No activation, user settings, helper or server.
@MainActor @Test func renderReviewedScreensWithoutTakingFocus() async throws {
    guard let directory = ProcessInfo.processInfo.environment["ANNOTATOR_REVIEW_SNAPSHOTS"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let model = AppModel(); model.demo = true; Demo.populate(model)
    model.items.append(.object(["id": .string("cancelled-fixture"), "number": .number(216), "status": .string("cancelled"), "comment": .string("Cancelled fixture"), "native": .object(["project": .string("Website")])]))
    model.state["queue"]["done"] = .number(3)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: MainWindow(model: model).frame(width: 1000, height: 680))
    window.contentView = view
    defer { window.close() }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        model.page = "settings"
        for section in ["general", "dictation"] {
            try await Task.sleep(for: .milliseconds(100))
            NotificationCenter.default.post(name: .demoSettingsSection, object: section)
            try await Task.sleep(for: .milliseconds(100))
            try capture(view, to: directory + "/\(name)-settings-\(section).png")
        }
        model.page = "projects"; model.selectedProjectID = "website"
        try await Task.sleep(for: .milliseconds(200))
        try capture(view, to: directory + "/\(name)-project-cancelled.png")
    }
}

@MainActor private func capture(_ view: NSView, to path: String) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
}
