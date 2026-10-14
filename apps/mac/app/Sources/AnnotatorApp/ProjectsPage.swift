import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

struct ProjectsPage: View {
    @Bindable var model: AppModel
    @State private var editing: JSON?
    @State private var deleting: JSON?
    private var projects: [JSON] {
        model.projects.filter { project in
            model.search.isEmpty || ["name", "root", "instructions"].map { project[$0].string }
                .joined(separator: " ").localizedCaseInsensitiveContains(model.search)
        }.sorted { $0["name"].string.localizedStandardCompare($1["name"].string) == .orderedAscending }
    }
    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            KitColumnDivider()
            if let project = model.selectedProject {
                ProjectDetail(model: model, project: project, edit: { editing = project }, delete: { deleting = project })
                    .id(project["id"].string)
            } else {
                VStack(spacing: 14) {
                    KitBrandMark(.annotator, size: 46).foregroundStyle(.primary).opacity(0.12)
                    Text("No project selected").font(.kitLabel).foregroundStyle(.tertiary)
                    HStack(spacing: 6) { KitKeyCap("⌘F"); Text("to search").font(.kitLabel).foregroundStyle(.tertiary) }
                }.padding(.bottom, 40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if !model.demo { await model.loadProjects() } }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing { ProjectEditor(model: model, initial: editing) { self.editing = nil } }
        }
        .confirmationDialog("Delete \(deleting?["name"].string ?? "project")? Its annotations stay on the server.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete project", role: .destructive) {
                guard let project = deleting else { return }
                Task { do { try await saveProjects(model, model.projects.filter { $0["id"] != project["id"] }) } catch { model.error = error.localizedDescription } }
                deleting = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoProjectEditor)) { note in
            editing = note.object as? String == "add" ? newProject() : model.selectedProject ?? model.projects.first ?? newProject()
        }
    }
    private var list: some View {
        ScrollViewReader { proxy in
            KitScrollView {
                LazyVStack(spacing: 2) {
                    if !model.projectsError.isEmpty { KitGroup { KitNotice(model.projectsError, tone: .error) } }
                    ForEach(projects, id: \.self) { project in
                        EntryListRow(title: project["name"].string, subtitle: projectSubtitle(project), selected: model.selectedProjectID == project["id"].string) {
                            model.selectedProjectID = project["id"].string
                        } icon: { ProjectIcon() } trailing: { EmptyView() }
                        .id(project["id"].string)
                    }
                }.padding(Kit.columnMargin).padding(.bottom, 28)
            }
            .overlay {
                if projects.isEmpty && model.projectsError.isEmpty {
                    VStack(spacing: 4) {
                        Text(model.search.isEmpty ? "No projects yet" : "No matches").font(.kitLabel)
                        Text(model.search.isEmpty ? "Add a project with +." : "Try another name or folder.").font(.kitDetail).foregroundStyle(.tertiary)
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .kitTopBar {
                HStack(spacing: 8) {
                    if model.searching { KitHeaderSearchField(text: $model.search, onClose: { model.search = ""; model.searching = false }) }
                    else { Text("Projects").font(.kitTitle); Spacer() }
                    KitToolbarGroup {
                        if !model.searching { KitToolbarButton(icon: .search, help: "Search projects (⌘F)") { model.searching = true } }
                        KitToolbarButton(icon: .plus, help: "Add project") { editing = newProject() }.disabled(model.projectsSaving || !model.projectsError.isEmpty)
                        KitToolbarMenu {
                            Button("Copy prompt for all annotations") { model.act("copy_prompt", ["scope": .string("all")]) }
                            Button("Copy inbox prompt") { model.act("copy_prompt", ["scope": .string("inbox")]) }
                        }
                    }
                }.padding(.leading, Kit.columnContent).padding(.trailing, Kit.columnMargin).frame(height: Kit.containerBarHeight)
            }
            .onChange(of: model.selectedProjectID) { _, id in proxy.scrollTo(id) }
            .focusable().focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
        }
    }
    private func move(_ direction: Int) {
        guard !projects.isEmpty else { return }
        let index = projects.firstIndex { $0["id"].string == model.selectedProjectID } ?? (direction > 0 ? -1 : projects.count)
        model.selectedProjectID = projects[max(0, min(projects.count - 1, index + direction))]["id"].string
    }
    private func projectSubtitle(_ project: JSON) -> String {
        let links = project["urlPrefixes"].array + project["bundleIds"].array
        return links.first?.string ?? (project["root"].string.isEmpty ? "No routing rules" : project["root"].string)
    }
}

struct ProjectIcon: View {
    var body: some View {
        KitIconImage(.folder, size: 14).foregroundStyle(.secondary)
            .frame(width: 26, height: 26).background(Color.kitTile, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ProjectDetail: View {
    @Bindable var model: AppModel
    let project: JSON
    let edit: () -> Void
    let delete: () -> Void
    private var annotations: [JSON] { AnnotationCollection.items(model.items, page: "project:" + project["id"].string, projects: model.projects, search: "") }
    private var position: Int { model.projects.firstIndex { $0["id"] == project["id"] } ?? 0 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                KitGroup("Annotations") {
                    KitFieldRow("Open", value: "\(annotations.filter { ["todo", "in_progress"].contains($0["status"].string) }.count)", copyable: false)
                    KitFieldRow("Finished", value: "\(annotations.filter { $0["status"].string == "done" }.count)", copyable: false)
                    KitActionRow("View annotations (\(annotations.count))", icon: .allItems) { model.navigate("project:" + project["id"].string) }
                }
                KitGroup("Project") {
                    KitFieldRow("Name", value: project["name"].string, lines: 4)
                    KitFieldRow("Folder", value: project["root"].string.isEmpty ? "Not set" : project["root"].string, lines: 4)
                    KitFieldRow("Instructions", value: project["instructions"].string.isEmpty ? "None" : project["instructions"].string, lines: 30)
                }
                KitGroup("Routing", footer: "Annotations from the chosen app or under the URL prefix go here. When both are set, both must match. The first matching project wins; the rest go to the Inbox.") {
                    KitFieldRow("App", value: rules("bundleIds"), lines: 4)
                    KitFieldRow("URL prefix", value: rules("urlPrefixes"), lines: 4)
                    KitFieldRow("Priority", value: "\(position + 1) of \(model.projects.count)", copyable: false)
                }
            }.frame(maxWidth: 600, alignment: .leading).padding(Kit.columnMargin).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
        }.kitBottomFade().kitTopBar {
            HStack(spacing: 8) {
                ProjectIcon()
                Text(project["name"].string).font(.kitTitle).lineLimit(1)
                Spacer(minLength: 8)
                KitToolbarGroup {
                    KitToolbarButton("Edit", action: edit)
                    KitToolbarMenu {
                        Button("Copy agent prompt") { model.act("copy_prompt", ["scope": project["id"]]) }
                        Divider()
                        Button("Route earlier") { reorder(-1) }.disabled(position == 0)
                        Button("Route later") { reorder(1) }.disabled(position == model.projects.count - 1)
                        Divider()
                        Button("Delete project…", role: .destructive, action: delete)
                    }
                }.disabled(model.projectsSaving || !model.projectsError.isEmpty)
            }.padding(.horizontal, Kit.columnMargin).frame(height: Kit.containerBarHeight)
        }
    }
    private func rules(_ key: String) -> String { project[key].array.isEmpty ? "Not set" : project[key].array.map(\.string).joined(separator: "\n") }
    private func reorder(_ direction: Int) {
        guard model.projects.indices.contains(position + direction) else { return }
        var projects = model.projects; projects.swapAt(position, position + direction)
        Task { do { try await saveProjects(model, projects) } catch { model.error = error.localizedDescription } }
    }
}

func newProject() -> JSON { .object(["id": .string(UUID().uuidString.lowercased()), "name": .string(""), "root": .string(""), "bundleIds": .array([]), "urlPrefixes": .array([]), "instructions": .string("")]) }
@MainActor func saveProjects(_ model: AppModel, _ projects: [JSON]) async throws {
    guard !model.projectsSaving else { throw BridgeError("Projects are still saving. Try again.") }
    model.projectsSaving = true; defer { model.projectsSaving = false }
    let result = try await model.call("save_projects", ["routes": .object(["projects": .array(projects)])])
    if result != .null { throw BridgeError(result.string) }
    model.projects = projects
    if model.selectedProject == nil { model.selectedProjectID = "" }
}
struct ProjectEditor: View {
    @Bindable var model: AppModel
    let initial: JSON
    let dismiss: () -> Void
    @State private var draft: JSON = .null
    @State private var busy = false
    @State private var error: String?
    private var isNew: Bool { !model.projects.contains { $0["id"] == initial["id"] } }
    var body: some View {
        KitSheet(isNew ? "Add project" : "Edit project", borderedHeader: true) {
                VStack(spacing: 22) {
                    KitGroup("Project", footer: isNew ? nil : "Existing annotations keep the project name they were captured with.") {
                        KitInputRow("Name", text: text("name"), prompt: "Project name", focusOnAppear: true)
                        KitInputRow("Folder", text: text("root"), prompt: "Choose the project folder") {
                            KitIconButton(.folder, help: "Choose folder") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { draft["root"] = .string(panel.url?.path ?? "") } }
                        }
                        KitInputRow("Instructions", text: text("instructions"), prompt: "Added to the agent prompt", lines: 3...8)
                    }
                    KitGroup("Routing", footer: "Annotations from the chosen app or under the URL prefix go here. When both are set, both must match. The first matching project wins; the rest go to the Inbox.") {
                        if !draft["bundleIds"].array.isEmpty {
                            KitLabeledRow("App") {
                                Text(draft["bundleIds"].array.map(\.string).joined(separator: "\n")).font(.kitBody).textSelection(.enabled)
                                Spacer(minLength: 8)
                                KitIconButton(.clear, help: "Remove app") { draft["bundleIds"] = .array([]) }
                            }
                        }
                        KitActionRow("Use last annotated app", icon: .desktop) { Task { do {
                            let last = try await model.call("last_target_app")
                            guard last != .null, !last["bundleId"].string.isEmpty else { throw BridgeError("Annotate an app first.") }
                            draft["bundleIds"] = .array([last["bundleId"]])
                        } catch { self.error = error.localizedDescription } } }
                        KitInputRow("URL prefix", text: urlPrefix, prompt: "https://example.com")
                    }
                }
        } actions: {
            Button("Cancel", action: dismiss).buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction).disabled(busy)
            Button(isNew ? "Add project" : "Save") { Task {
                busy = true; error = nil; defer { busy = false }
                var updated = model.projects
                if let index = updated.firstIndex(where: { $0["id"] == draft["id"] }) { updated[index] = draft } else { updated.append(draft) }
                do {
                    try await saveProjects(model, updated)
                    model.selectedProjectID = draft["id"].string; model.search = ""; model.searching = false
                    dismiss()
                } catch { self.error = error.localizedDescription }
            } }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(busy || model.projectsSaving || draft["name"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.frame(width: 560, height: 640).onAppear { draft = initial }.interactiveDismissDisabled(busy)
        .alert("Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { draft[key].string }, set: { draft[key] = .string($0) }) }
    /// One prefix; an empty field removes it.
    private var urlPrefix: Binding<String> { Binding(get: { draft["urlPrefixes"].array.first?.string ?? "" }, set: { let value = $0.trimmingCharacters(in: .whitespaces); draft["urlPrefixes"] = .array(value.isEmpty ? [] : [.string(value)]) }) }
}
extension Notification.Name { static let demoProjectEditor = Notification.Name("demo-project-editor") }
