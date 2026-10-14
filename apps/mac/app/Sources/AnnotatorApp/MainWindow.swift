import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

struct MainWindow: View {
    @Bindable var model: AppModel
    var body: some View {
        KitShell(sidebarWidth: 220) { sidebar } content: {
            if model.page == "settings" { SettingsPage(model: model) }
            else if model.page == "projects" { ProjectsPage(model: model) }
            else { HStack(spacing: 0) { AnnotationList(model: model).frame(width: 300); KitColumnDivider(); AnnotationDetail(model: model) } }
        }
        .kitAppearance()
        .onChange(of: model.page) { _, _ in
            model.marked = []
            if !["settings", "projects"].contains(model.page), !model.filtered.contains(where: { $0["id"].string == model.selected }) { model.selected = "" }
        }
        .alert("Annotator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            // The first row lines up with the first row of the list beside it.
            Color.clear.frame(height: Kit.barHeight - Kit.shellInset + Kit.columnMargin + Self.rowOffset)
            VStack(spacing: 2) {
                row("All annotations", .allItems, "all", model.items.count)
                row("Open", .clock, "open", model.state["queue"]["todo"].int + model.state["queue"]["inProgress"].int)
                row("Finished", .done, "done", model.state["queue"]["done"].int)
                row("Projects", .folder, "projects", model.projects.count)
            }.padding(.horizontal, Kit.sidebarInset)
            Spacer()
            VStack(spacing: 2) {
                row("Settings", .settings, "settings", nil)
            }.padding(Kit.sidebarInset)
        }
    }
    /// Half the difference between a list row (50 pt) and a sidebar row (31 pt), so their centres meet.
    static let rowOffset: CGFloat = 9.5
    private func row(_ title: String, _ icon: KitIcon, _ page: String, _ count: Int?) -> some View {
        KitSidebarRow(title, icon: icon, count: count, selected: model.page == page || (page == "projects" && model.page.hasPrefix("project:"))) { model.navigate(page) }
    }
}
struct PageBar<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack { Text(title).font(.kitTitle); Spacer(minLength: 8); actions }
            .padding(.leading, Kit.columnContent).padding(.trailing, Kit.columnMargin).frame(height: Kit.containerBarHeight)
    }
}
struct AnnotationList: View {
    @Bindable var model: AppModel
    @State private var clear = false
    @State private var archive: String?
    @State private var deleteMarked = false
    var body: some View {
        ScrollViewReader { proxy in
            KitScrollView {
                LazyVStack(spacing: 2) {
                    if model.state["health"]["tone"].string != "ok" {
                        KitGroup { KitNotice(model.state["health"]["title"].string.isEmpty ? "Connecting…" : model.state["health"]["title"].string,
                                  tone: model.state["health"]["tone"].string == "error" ? .error : .warning) }
                    }
                    if model.filtered.isEmpty {
                        VStack(spacing: 6) { Text(model.search.isEmpty ? "No annotations here" : "No matches").font(.kitLabel); Text(model.search.isEmpty ? "Use \(model.state["hotkey"]["display"].string) to annotate your screen." : "Try another word.").font(.kitDetail).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    ForEach(model.filtered, id: \.self) { item in
                        EntryListRow(title: item["comment"].string, subtitle: item["native"]["app"]["name"].string.isEmpty ? item["pathname"].string : item["native"]["app"]["name"].string, selected: model.selected == item["id"].string || model.marked.contains(item["id"].string)) {
                            pick(item["id"].string)
                        } icon: {
                            Text("\(item["number"].int)").font(.kitDetail.weight(.semibold)).monospacedDigit()
                                .frame(width: 26, height: 26).background(Color.kitTile, in: RoundedRectangle(cornerRadius: 7))
                        } trailing: {
                            KitIconImage(item["question"].bool ? .warning : item["status"].string == "done" ? .done : item["status"].string == "todo" ? .clock : .sync, size: 12).foregroundStyle(.secondary)
                        }.id(item["id"].string)
                    }
                }.padding(Kit.columnMargin).padding(.bottom, 28)
            }
            .onChange(of: model.selected) { _, id in proxy.scrollTo(id) }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .focusable().focusEffectDisabled()
            .kitTopBar {
                HStack(spacing: 8) {
                    if model.page.hasPrefix("project:") {
                        KitToolbarGroup { KitToolbarButton(icon: .restore, help: "Back to project") { model.navigate("projects") } }
                    }
                    if model.searching { KitHeaderSearchField(text: $model.search, onClose: { model.search = ""; model.searching = false }) }
                    else { Text(model.pageTitle).font(.kitTitle).lineLimit(1); Spacer() }
                    if model.marked.count > 1 {
                        KitToolbarGroup { KitToolbarButton(icon: .trash, help: "Delete \(model.marked.count) annotations") { deleteMarked = true } }
                    }
                    KitToolbarGroup {
                        if !model.searching { KitToolbarButton(icon: .search, help: "Search annotations") { model.searching = true } }
                        KitToolbarButton(icon: .plus, help: "Annotate screen") { model.act("toggle_annotating") }
                        KitToolbarMenu {
                            Button("Copy agent prompt") { model.act("copy_prompt", ["scope": .string(model.page.hasPrefix("project:") ? String(model.page.dropFirst("project:".count)) : "all")]) }
                            Divider()
                            Button("Archive finished annotations…") { archive = "done" }
                            Button("Archive all annotations…") { archive = "all" }
                            Button("Clear all open annotations…", role: .destructive) { clear = true }
                        }
                    }
                }.padding(.leading, Kit.columnContent).padding(.trailing, Kit.columnMargin).frame(height: Kit.containerBarHeight)
            }
        }
        .confirmationDialog(archiveTitle, isPresented: Binding(get: { archive != nil }, set: { if !$0 { archive = nil } })) {
            Button("Archive", role: .destructive) { delete(archiving.map { $0["id"].string }); archive = nil }
        } message: { Text("Archiving deletes them from the server.") }
        .confirmationDialog("Delete \(model.marked.count) annotations?", isPresented: $deleteMarked) {
            Button("Delete", role: .destructive) { delete(Array(model.marked)); model.marked = [] }
        }
        .confirmationDialog("Delete open annotations from all projects? Finished annotations stay.", isPresented: $clear) {
            Button("Delete open annotations", role: .destructive) { Task { do { let result = try await model.call("clear_open"); if result["failed"].int > 0 { model.error = "\(result["failed"].int) annotations could not be deleted." } } catch { model.error = error.localizedDescription } } }
        }
    }
    /// The annotations on this page that an archive removes: the finished ones, or all of them.
    private var archiving: [JSON] { model.filtered.filter { archive == "all" || $0["status"].string == "done" } }
    private var archiveTitle: String {
        let count = archiving.count
        return "Archive \(count) \(archive == "all" ? "" : "finished ")annotation\(count == 1 ? "" : "s") on \(model.pageTitle)?"
    }
    private func delete(_ ids: [String]) {
        Task {
            var failed = 0
            for id in ids { do { _ = try await model.call("delete_annotation", ["id": .string(id)]) } catch { failed += 1 } }
            if failed > 0 { model.error = "\(failed) annotations could not be deleted." }
        }
    }
    /// A plain click selects; ⌘-click adds or removes a row; ⇧-click adds the rows up to it.
    private func pick(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            if model.marked.isEmpty, !model.selected.isEmpty { model.marked = [model.selected] }
            if flags.contains(.shift), let from = model.filtered.firstIndex(where: { $0["id"].string == model.selected }),
               let to = model.filtered.firstIndex(where: { $0["id"].string == id }) {
                model.marked.formUnion(model.filtered[min(from, to)...max(from, to)].map { $0["id"].string })
            } else if model.marked.contains(id) { model.marked.remove(id) } else { model.marked.insert(id) }
        } else {
            model.marked = []
        }
        model.selected = id
    }
    private func move(_ offset: Int) {
        let items = model.filtered; guard !items.isEmpty else { return }
        let index = items.firstIndex { $0["id"].string == model.selected } ?? -1
        model.selected = items[max(0, min(items.count - 1, index + offset))]["id"].string
    }
}
struct AnnotationRow: View {
    let item: JSON
    var body: some View {
        HStack(spacing: 10) {
            Text("\(item["number"].int)").font(.kitDetail.weight(.semibold)).monospacedDigit()
                .frame(width: 26, height: 26).background(Color.kitTile, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(item["comment"].string).font(.kitBody).lineLimit(1)
                Text(item["native"]["app"]["name"].string.isEmpty ? item["pathname"].string : item["native"]["app"]["name"].string).font(.kitDetail).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            KitIconImage(item["question"].bool ? .warning : item["status"].string == "done" ? .done : item["status"].string == "todo" ? .clock : .sync, size: 12).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
    }
}

/// The same entry row in both collection columns, using Vault's 26 pt tile and 50 pt row.
struct EntryListRow<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.kitBody).lineLimit(1)
                    Text(subtitle).font(.kitDetail).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }.padding(.horizontal, Kit.rowInset).frame(height: 50)
                .background(selected ? Color.kitSelection : hovering ? Color.kitHover : .clear, in: RoundedRectangle(cornerRadius: Kit.Radius.row))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
