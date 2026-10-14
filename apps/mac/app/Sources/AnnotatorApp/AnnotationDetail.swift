import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

struct AnnotationDetail: View {
    @Bindable var model: AppModel
    @State private var screenshot: NSImage?
    @State private var screenshotError: String?
    @State private var loading = false
    @State private var lightbox = false
    @State private var deleting = false
    @State private var copied = false
    var body: some View {
        Group {
            if let item = model.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let screenshot {
                            Button { lightbox = true } label: { Image(nsImage: screenshot).resizable().scaledToFit().frame(maxWidth: .infinity) }
                                .buttonStyle(.plain).help("View full screenshot")
                        } else { Text(loading ? "Loading screenshot…" : screenshotError ?? "No screenshot.").font(.kitDetail).foregroundStyle(.secondary).padding(.horizontal, Kit.rowInset) }
                        KitGroup {
                            KitFieldRow("Comment", value: item["comment"].string, lines: 30)
                            if !item["summary"].string.isEmpty { KitFieldRow(item["question"].bool ? "Agent asks" : "Agent", value: item["summary"].string, lines: 30) }
                        }
                        KitGroup("Context") {
                            ForEach(properties(item), id: \.0) { label, value in KitFieldRow(label, value: value, lines: 4) }
                        }
                        Text(item["id"].string).font(.kitDetail).foregroundStyle(.tertiary).textSelection(.enabled).padding(.horizontal, Kit.rowInset)
                    }.frame(maxWidth: 600, alignment: .leading).padding(Kit.columnMargin).padding(.bottom, 28)
                }.kitBottomFade().kitTopBar {
                    PageBar(title: "Annotation #\(item["number"].int)") {
                        KitToolbarGroup {
                            KitToolbarButton(icon: copied ? .check : .copy, help: copied ? "Copied" : "Copy comment") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item["comment"].string, forType: .string); copied = true }
                            KitToolbarMenu { Button("Delete annotation…", role: .destructive) { deleting = true } }
                        }
                    }
                }
            } else {
                VStack(spacing: 14) { KitBrandMark(.annotator, size: 46).foregroundStyle(.primary).opacity(0.12); Text(model.selected.isEmpty ? "No annotation selected" : "This annotation is no longer on the server.").font(.kitLabel).foregroundStyle(.secondary); KitKeyCap("⌘F") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(1.6)); copied = false } }
        .task(id: model.selected) {
            screenshot = nil; screenshotError = nil
            guard !model.selected.isEmpty else { return }; loading = true; defer { loading = false }
            do {
                let data = model.demo ? Demo.screenshot : try await model.call("get_screenshot", ["id": .string(model.selected)]).string
                guard !Task.isCancelled else { return }
                if let comma = data.firstIndex(of: ","), let bytes = Data(base64Encoded: String(data[data.index(after: comma)...])) { screenshot = NSImage(data: bytes) }
            } catch { screenshotError = error.localizedDescription }
        }
        .sheet(isPresented: $lightbox) {
            if let screenshot { ScreenshotView(image: screenshot) { lightbox = false } }

        }
        .confirmationDialog("Delete this annotation?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { model.act("delete_annotation", ["id": .string(model.selected)]) }
        }
    }
    private func properties(_ item: JSON) -> [(String, String)] {
        var rows = [("Status", AnnotationCollection.statusTitle(item["status"].string)), ("Project", item["native"]["project"].string), ("Element", item["element"].string), ("Component", item["component"].string), ("React", item["react"].string), ("Selector", item["native"]["dom"]["selector"].string), ("Path", item["elementPath"].string), ("URL", item["url"].string), ("Window", item["pathname"].string), ("App", item["native"]["app"]["name"].string), ("Bundle ID", item["native"]["app"]["bundleId"].string), ("Mode", item["native"]["mode"].string.capitalized), ("Screen", item["screenSize"].string)]
        let box = item["boundingBox"]
        if box != .null { rows.append(("Bounds", "\(box["x"].int), \(box["y"].int) · \(box["width"].int) × \(box["height"].int) pt")) }
        for (label, key) in [("Created", "createdAt"), ("Claimed", "claimedAt"), ("Completed", "completedAt")] {
            if item[key].double > 0 { rows.append((label, Date(timeIntervalSince1970: item[key].double / 1000).formatted())) }
        }
        return rows.filter { !$0.1.isEmpty }
    }
}

struct ScreenshotView: View {
    let image: NSImage
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Screenshot").font(.kitTitle); Spacer(); KitToolbarGroup { KitToolbarButton("Done", action: close).keyboardShortcut(.cancelAction) } }.padding(20)
            ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(width: min(image.size.width, 1000)) }
        }.frame(width: 800, height: 560).background(Color.kitContent)
    }
}
