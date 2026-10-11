import Inject
import AnnotatorCore
import AppKit
import SwiftUI

/// One annotation with its screenshot and every property. Follows the live queue, so the status updates.
struct AnnotationDetailView: View {
    @ObserveInjection var injection
    let id: String
    let queue: QueueMonitor

    /// The title bar's height with an empty unified toolbar. That style moves the window buttons
    /// inward and down; the custom title and status are centered in the same bar.
    static let titleBarHeight: CGFloat = {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        AnnotationDetailView.styleTitleBar(window)
        return window.frame.height - window.contentLayoutRect.height
    }()

    /// Applied to every annotation window, and to the one that measures `titleBarHeight`.
    /// The window has no safe area: the view starts under the transparent title bar and draws `titleBar` there.
    /// Without this the window keeps the title bar's height for the view, which shows as empty space at the bottom.
    static func styleTitleBar(_ window: NSWindow) {
        (window.contentViewController as? NSHostingController<AnnotationDetailView>)?.safeAreaRegions = []
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        // Let the frosted background show; an opaque window background would cover it.
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    static let width: CGFloat = 680
    static let padding: CGFloat = 20
    static var contentWidth: CGFloat { width - 2 * padding }

    var body: some View {
        Group {
            if let item = queue.summary?.item(id: id) {
                VStack(spacing: 0) {
                    titleBar(item)
                    Divider()
                    // No scroll view: the window takes the size of its content, so everything is visible.
                    VStack(alignment: .leading, spacing: 18) {
                        if let image = AnnotationDetailView.image(item.screenshot) {
                            ScreenshotPreview(image: image, width: AnnotationDetailView.contentWidth)
                        } else {
                            Text("No screenshot.").foregroundStyle(.secondary)
                        }
                        properties(item)
                    }
                    .padding(AnnotationDetailView.padding)
                }
                .frame(width: AnnotationDetailView.width)
                // One text size for the whole panel.
                .font(.system(size: 14))
                // Frosted glass, like the Finder sidebar: the desktop behind the window shows through, blurred.
                .background(FrostedBackground.layer)
            } else {
                Text("This annotation is no longer on the server.")
                    .foregroundStyle(.secondary)
                    .frame(width: AnnotationDetailView.width, height: 200)
                    .background(FrostedBackground.layer)
            }
        }
        .enableInjection()
    }

    /// Replaces the system title bar: the title in the middle, the status on the right.
    private func titleBar(_ item: QueueItem) -> some View {
        ZStack {
            Text("Annotation #\(item.number.map(String.init) ?? "?")").fontWeight(.semibold)
            HStack {
                Spacer()
                // The icon alone shows the status; the tooltip names it.
                Group {
                    if item.isInProgress {
                        // The system spinner is dim on a dark bar; brighten it.
                        ProgressView().controlSize(.small).brightness(0.45)
                    } else {
                        Image(systemName: AnnotationRowView.symbol(for: item))
                            .foregroundStyle(item.needsAnswer ? .orange : item.isOpen ? .secondary : Color.green)
                    }
                }
                .help(statusText(item))
            }
            .padding(.trailing, AnnotationDetailView.padding)
        }
        .frame(height: AnnotationDetailView.titleBarHeight)
    }

    private func statusText(_ item: QueueItem) -> String {
        if item.needsAnswer { return "Question for you" }
        switch item.status {
        case "todo": return "To do"
        case "in_progress": return "In progress"
        case "done": return "Done"
        default: return item.status.capitalized
        }
    }

    private struct Row {
        var label: String
        var value: String?
        /// Prose wraps; everything else stays on one line.
        var wraps = false
    }

    private func properties(_ item: QueueItem) -> some View {
        let summary = item.summary.flatMap { $0.isEmpty ? nil : $0 }
        let rows: [Row] = [
            Row(label: "Comment", value: item.comment, wraps: true),
            Row(label: item.needsAnswer ? "Agent asks" : "Agent", value: summary, wraps: true),
            Row(label: "Project", value: item.native?.project),
            Row(label: "Element", value: item.element),
            Row(label: "Component", value: item.component),
            Row(label: "React", value: item.react),
            Row(label: "Selector", value: item.native?.dom?.selector),
            Row(label: "Path", value: item.elementPath),
            Row(label: "URL", value: item.url),
            Row(label: "Window", value: item.pathname),
            Row(label: "App", value: item.native?.app.map { "\($0.name) (\($0.bundleId ?? "no bundle id"))" }),
            Row(label: "Mode", value: item.native?.mode),
            Row(label: "Box", value: item.boundingBox.map {
                "x \(Int($0.x)), y \(Int($0.y)), \(Int($0.width)) × \(Int($0.height)) pt"
            }),
            Row(label: "Screen", value: item.screenSize),
            Row(label: "Created", value: date(item.createdAt)),
            Row(label: "Claimed", value: date(item.claimedAt)),
            Row(label: "Completed", value: date(item.completedAt)),
            Row(label: "ID", value: item.id),
        ]
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            ForEach(rows.filter { $0.value != nil }, id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    if row.wraps {
                        Text(row.value ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Long values are shortened in the middle; hover shows the full value.
                        Text(row.value ?? "").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.value ?? "")
                    }
                }
            }
        }
    }

    private func date(_ milliseconds: Int64?) -> String? {
        milliseconds.map {
            Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .standard)
        }
    }

    static func image(_ dataURL: String?) -> NSImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ","),
            let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }
}

/// The screenshot at the full content width, aspect ratio kept.
/// Wide images show whole. Images taller than 16:9 show their top part in a 16:9 box.
/// A click opens the full-size view.
struct ScreenshotPreview: View {
    @ObserveInjection var injection
    let image: NSImage
    /// The preview's width. Its height follows from it, so the layout never squeezes the box.
    let width: CGFloat
    @State private var hovering = false
    private static let ratio: CGFloat = 16 / 9

    private var aspect: CGFloat { image.size.height > 0 ? image.size.width / image.size.height : ScreenshotPreview.ratio }
    private var isTall: Bool { aspect < ScreenshotPreview.ratio }
    private var height: CGFloat { width / max(aspect, ScreenshotPreview.ratio) }

    var body: some View {
        Group {
            Group {
                if isTall {
                    // Like CSS object-fit: cover, anchored at the top.
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width, height: width / aspect)
                        .frame(width: width, height: height, alignment: .top)
                        .clipped()
                        .overlay(alignment: .bottomTrailing) {
                            Text("Cropped")
                                .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        }
                } else {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: width, height: height)
            .overlay {
                if hovering {
                    ZStack {
                        Color.black.opacity(0.35)
                        Label("Click to view the full image", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .contentShape(Rectangle())
            .onTapGesture { Lightbox.show(image) }
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .enableInjection()
    }
}

/// Frosted glass behind the whole panel, like the Finder sidebar: Liquid Glass on macOS 26 and later,
/// otherwise the sidebar blur. Both show the desktop behind the window, blurred.
struct FrostedBackground: NSViewRepresentable {
    /// How much of the window color covers the glass: 0 shows the most of what is behind, 1 none of it.
    static let frost: Double = 0.5

    /// The glass with the frost layer on top.
    @MainActor static var layer: some View {
        ZStack {
            FrostedBackground()
            Color(nsColor: .windowBackgroundColor).opacity(frost)
        }
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            return glass
        }
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Keep the blur when the window is inactive; following the window state makes it opaque then.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
