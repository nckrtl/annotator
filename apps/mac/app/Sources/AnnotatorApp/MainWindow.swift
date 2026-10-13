import SwiftUI
import DesignKit
import AnnotatorCore

struct AnnotatorMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Color.kitInk)
            KitIconImage(.edit, size: size * 0.52).foregroundStyle(Color.kitOnInk)
            Circle().fill(Color.kitOnInk).frame(width: size * 0.12, height: size * 0.12).offset(x: -size * 0.22, y: size * 0.22)
        }.frame(width: size, height: size).accessibilityLabel("Annotator")
    }
}
struct MainWindow: View {
    @Bindable var model: AppModel
    var body: some View {
        KitShell(sidebarWidth: 220) { sidebar } content: {
            if model.page == "settings" { SettingsPage(model: model) }
            else if model.page == "projects" { ProjectsPage(model: model) }
            else { HStack(spacing: 0) { AnnotationList(model: model).frame(width: 300); KitColumnDivider(); AnnotationDetail(model: model) } }
        }
        .onChange(of: model.page) { _, _ in
            if !["settings", "projects"].contains(model.page), !model.filtered.contains(where: { $0["id"].string == model.selected }) { model.selected = "" }
        }
        .alert("Annotator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                KitIconButton(.sync, help: model.state["health"]["title"].string) { model.act("retry_now"); Task { await model.load() } }
                KitIconButton(.edit, help: "Annotate screen") { model.act("toggle_annotating") }
            }.padding(.trailing, 14).frame(height: Kit.barHeight)
            VStack(spacing: 2) {
                KitSectionLabel("Annotations")
                row("All annotations", .allItems, "all", model.items.count)
                row("Open", .clock, "open", model.state["queue"]["todo"].int + model.state["queue"]["inProgress"].int)
                row("Finished", .done, "done", model.state["queue"]["done"].int)
                if !model.projects.isEmpty {
                    KitSectionLabel("Projects")
                    ForEach(model.projects, id: \.self) { project in
                        row(project["name"].string, .folder, "project:" + project["id"].string, nil)
                    }
                }
            }.padding(.horizontal, Kit.sidebarInset)
            Spacer()
            VStack(spacing: 2) {
                row("Manage projects", .folder, "projects", nil)
                row("Settings", .settings, "settings", nil)
            }.padding(Kit.sidebarInset)
        }
    }
    private func row(_ title: String, _ icon: KitIcon, _ page: String, _ count: Int?) -> some View {
        KitSidebarRow(title, icon: icon, count: count, selected: model.page == page) { model.page = page; model.search = "" }
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
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
                        Button { model.selected = item["id"].string } label: {
                            AnnotationRow(item: item).padding(Kit.rowInset)
                                .background(model.selected == item["id"].string ? Color.kitSelection : .clear, in: RoundedRectangle(cornerRadius: Kit.Radius.row))
                        }.buttonStyle(.plain).id(item["id"].string)
                    }
                }.padding(Kit.columnMargin).padding(.bottom, 28)
            }
            .onChange(of: model.selected) { _, id in proxy.scrollTo(id) }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .focusable().focusEffectDisabled()
            .kitBottomFade()
            .kitTopBar {
                HStack(spacing: 8) {
                    if model.searching { KitSearchField(text: $model.search, onClose: { model.search = ""; model.searching = false }) }
                    else { Text(model.pageTitle).font(.kitTitle); Spacer() }
                    KitToolbarGroup {
                        if !model.searching { KitToolbarButton(icon: .search, help: "Search annotations") { model.searching = true } }
                        KitToolbarButton(icon: .plus, help: "Annotate screen") { model.act("toggle_annotating") }
                        KitToolbarMenu { Button("Copy agent prompt") { model.act("copy_prompt", ["scope": .string("all")]) }; Button("Clear open annotations…", role: .destructive) { clear = true } }
                    }
                }.padding(.leading, Kit.columnContent).padding(.trailing, Kit.columnMargin).frame(height: Kit.containerBarHeight)
            }
        }
        .confirmationDialog("Delete all open annotations? Finished annotations stay.", isPresented: $clear) {
            Button("Delete open annotations", role: .destructive) { Task { do { let result = try await model.call("clear_open"); if result["failed"].int > 0 { model.error = "\(result["failed"].int) annotations could not be deleted." } } catch { model.error = error.localizedDescription } } }
        }
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
