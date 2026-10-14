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
            } catch { model.error = error.localizedDescription; model.cancelComment() }
        }
    }

    /// Native Operator captures the workspace PID at start. Key status alone is insufficient.
    func prepareDictation() async throws {
        focusComment()
        for _ in 0..<20 {
            try Task.checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
               NSApp.isActive, let panel = commentPanel, panel.isKeyWindow,
               let field = panel.firstResponder as? NSTextView, field.isEditable {
                DictationLog.write("dictation-focus-confirmed pid=\(getpid()) workspace=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        DictationLog.write("dictation-focus-failed pid=\(getpid()) workspace=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) active=\(NSApp.isActive) key=\(commentPanel?.isKeyWindow ?? false)")
        throw BridgeError("The comment field could not get focus. Click it and try again, or type your comment.")
    }

    func makeComment() -> NSPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CommentView(model: model).kitAppearance())
        commentPanel = panel; return panel
    }
    func focusComment() { NSApp.activate(ignoringOtherApps: true); commentPanel?.makeKeyAndOrderFront(nil); NotificationCenter.default.post(name: .focusComment, object: nil) }
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
                KitToolbarGroup { KitToolbarButton(icon: .close, help: "Cancel comment") { model.cancelComment() }.keyboardShortcut(.cancelAction) }
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
                    KitIconButton(.microphone, help: model.dictation == "recording" ? "Stop dictation" : "Dictate comment") {
                        focused = true
                        if model.dictation == "recording" { Task { do { try await model.finishDictation() } catch { model.commentError = error.localizedDescription } } }
                        else { model.startDictation() }
                    }.disabled(model.commentBusy || ["starting", "transcribing"].contains(model.dictation))
                    Text(model.dictation == "idle" ? "Dictate" : model.dictation.capitalized + "…").font(.kitDetail).foregroundStyle(.secondary)
                    if model.dictation == "transcribing" {
                        KitStatusIcon(.working, size: 12).accessibilityHidden(true)
                    }
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
/// The menu-bar flyout, laid out like Operator's panel (`MenuBarPanelView`): a header bar with the
/// title and one ⋯ menu, then notices and the recent annotations as plain hover rows.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @State private var contentHeight: CGFloat = 480
    @State private var scrolled = false
    private static let maxHeight: CGFloat = 620
    private var pending: Int { model.state["pending"]["count"].int }
    private var failed: Int { model.state["failedCount"].int }
    /// Pending and refused comments have their own notices; any other unhealthy state shows here.
    private var healthNotice: Bool {
        let tone = model.state["health"]["tone"].string
        return tone == "error" || (tone == "warning" && pending == 0 && failed == 0)
    }
    var body: some View {
        let days = Self.days(model.items)
        KitScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if healthNotice { KitGroup { KitNotice(model.state["health"]["title"].string, tone: model.state["health"]["tone"].string == "error" ? .error : .warning) }.padding(.bottom, Kit.Space.m) }
                if pending > 0 {
                    KitGroup { KitNotice("\(pending) comments are waiting to send.", tone: .warning) { Button("Retry") { model.act("retry_now") }.buttonStyle(.kit) } }.padding(.bottom, Kit.Space.m)
                }
                if failed > 0 { Button("Show \(failed) refused comments") { model.act("show_failed") }.buttonStyle(.kit).padding(.bottom, Kit.Space.m) }
                if model.items.isEmpty { MenuEmpty(hotkey: model.state["hotkey"]["display"].string) }
                // As in Operator's transcript list: every annotation, newest first, under day headings.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(days, id: \.label) { day in
                        Text(verbatim: day.label).font(.kitSection).foregroundStyle(.secondary)
                            .padding(.leading, Kit.rowInset)
                            .padding(.top, day.label == days.first?.label ? 2 : Kit.Space.xxl)
                            .padding(.bottom, Kit.Space.xs)
                        ForEach(day.items, id: \.["id"].string) { item in
                            MenuAnnotationRow(item: item) { model.navigate("all", id: item["id"].string) }
                        }
                    }
                }
            }
            .padding(.horizontal, Kit.columnMargin).padding(.bottom, 28)
            // A lazy stack re-estimates its height while it scrolls. Stop at the panel's limit, so
            // that does not resize the menu bar window on every scroll step.
            .onGeometryChange(for: CGFloat.self) { min($0.size.height, Self.maxHeight) } action: { contentHeight = $0 }
        }
        .scrollIndicators(.never)
        // The list starts below the header and scrolls behind its frosted surface.
        .contentMargins(.top, Kit.containerBarHeight, for: .scrollContent)
        .kitBottomFade()
        // Like a sheet header: the line under the header shows only once content scrolls under it.
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, value in
            withAnimation(Kit.Motion.fast) { scrolled = value }
        }
        .overlay(alignment: .top) {
            header.background { KitHeaderSurface().opacity(scrolled ? 1 : 0) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.kitSeparator).frame(height: 0.5).opacity(scrolled ? 1 : 0) }
        }
        // A ScrollView has no intrinsic height. A maximum alone collapses MenuBarExtra
        // to a strip; give its host a measured height and scroll only when needed.
        .frame(width: 360, height: min(Kit.containerBarHeight + contentHeight, min(Self.maxHeight, (NSScreen.main?.visibleFrame.height ?? 700) - 24)))
        .background(Color.kitContent).background(WindowReader { model.panels?.menu = $0 })
    }
    /// Annotations by day, newest first, labelled as Operator labels transcriptions.
    static func days(_ items: [JSON], now: Date = Date(), calendar: Calendar = .current) -> [(label: String, items: [JSON])] {
        var days: [(label: String, items: [JSON])] = []
        for item in items.sorted(by: { $0["number"].int > $1["number"].int }) {
            let label = dayLabel(item["createdAt"].double, now: now, calendar: calendar)
            if days.last?.label == label { days[days.count - 1].items.append(item) } else { days.append((label, [item])) }
        }
        return days
    }
    private static func dayLabel(_ milliseconds: Double, now: Date, calendar: Calendar) -> String {
        guard milliseconds > 0 else { return "Earlier" }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if diff == 0 { return "Today" }
        if diff == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(diff < 7 ? "EEEE" : sameYear ? "MMMMd" : "MMMMdy")
        return formatter.string(from: date)
    }
    /// As in Operator: the title starts where row text starts, and one ⋯ menu holds the app's actions.
    private var header: some View {
        HStack(spacing: Kit.Space.m) {
            Text("Annotations").font(.kitTitle).padding(.leading, Kit.rowInset)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
            KitToolbarGroup {
                KitToolbarMenu(help: "More") {
                    Button("Open Annotator") { model.navigate("all") }
                    Button("Settings…") { model.navigate("settings") }.keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Button("Open server") { model.act("open_server") }
                    Button("Permissions…") { model.panels?.permissions() }
                    Button("Copy agent prompt") { model.act("copy_prompt", ["scope": .string("all")]) }
                    Divider()
                    Button("Quit Annotator") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                }
            }.accessibilityLabel("More actions")
        }
        .padding(.horizontal, Kit.columnMargin)
        .frame(height: Kit.containerBarHeight)
    }
}

/// One recent annotation, styled like Operator's transcript row: the source app's icon, the
/// comment, a detail line, and the status icon at the end. The whole row opens the annotation.
private struct MenuAnnotationRow: View {
    let item: JSON
    let action: () -> Void
    @State private var hovering = false
    private var status: (icon: KitIcon, label: String) {
        if item["question"].bool { return (.warning, "Question") }
        switch item["status"].string {
        case "done": return (.done, "Done")
        case "todo": return (.clock, "To do")
        default: return (.sync, "In progress")
        }
    }
    private var details: String {
        let app = item["native"]["app"]["name"].string.isEmpty ? item["pathname"].string : item["native"]["app"]["name"].string
        return [app, item["native"]["project"].string].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                MenuAppIcon(bundleId: item["native"]["app"]["bundleId"].string)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item["comment"].string).font(.kitBody).foregroundStyle(.primary).lineLimit(2)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    if !details.isEmpty { Text(details).font(.kitDetail).foregroundStyle(.secondary).lineLimit(1) }
                }
                KitIconImage(status.icon, size: 12).foregroundStyle(.secondary).padding(.top, 3).help(status.label)
            }
            .padding(Kit.rowInset)
            .background(hovering ? Color.kitHover : .clear, in: RoundedRectangle(cornerRadius: Kit.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Kit.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(item["comment"].string), \(status.label)")
    }
}

/// The installed app's icon at 26 pt, as in Operator's `AppIconTile`, or a quiet tile when unknown.
private struct MenuAppIcon: View {
    let bundleId: String
    /// Keeps misses too, so an app that is not installed is looked up once.
    @MainActor private static var cache: [String: NSImage?] = [:]
    private var image: NSImage? {
        if let image = Self.cache[bundleId] { return image }
        let url = bundleId.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.cache[bundleId] = image
        return image
    }
    var body: some View {
        Group {
            if let image {
                // macOS icons carry a margin around their shape; fill the tile with the shape.
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().scaleEffect(1.18)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 26 * 0.24, style: .continuous).fill(Color.kitTile)
                    KitIconImage(.allItems, size: 13).foregroundStyle(.secondary)
                }
            }
        }.frame(width: 26, height: 26).accessibilityHidden(true)
    }
}

/// No annotations yet: how to start, with the shortcut as a key cap (Operator's `TranscriptsEmpty`).
private struct MenuEmpty: View {
    let hotkey: String
    var body: some View {
        VStack(spacing: Kit.Space.xs) {
            KitIconImage(.allItems, size: 22).foregroundStyle(.tertiary).padding(.bottom, Kit.Space.m)
            Text("No annotations yet").font(.kitLabel).foregroundStyle(.secondary)
            if !hotkey.isEmpty {
                HStack(spacing: Kit.Space.xs) { Text("Press"); KitKeyCap(hotkey); Text("to annotate the screen.") }
            }
        }
        .font(.kitDetail).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
