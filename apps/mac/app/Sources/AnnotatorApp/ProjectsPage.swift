import SwiftUI
import AppKit
import DesignKit
import AnnotatorCore

struct ProjectsPage: View {
    @Bindable var model: AppModel
    @State private var editing: JSON?
    @State private var deleting: JSON?
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if !model.projectsError.isEmpty { KitGroup { KitNotice(model.projectsError, tone: .error) } }
                KitGroup("Routing", footer: "Every filled rule group must match. The first matching project wins. Unmatched annotations stay in the inbox.") {
                    if model.projects.isEmpty { KitRow("No projects yet", detail: "Add a project to route annotations and start agent sessions.") { EmptyView() } }
                    ForEach(model.projects, id: \.self) { project in
                        KitRow(project["name"].string, detail: project["root"].string) {
                            Button("Edit") { editing = project }.buttonStyle(.kit)
                            Menu {
                                Button("Copy agent prompt") { model.act("copy_prompt", ["scope": project["id"]]) }
                                Button("Start Conn session") { model.act("conn_start", ["projectId": project["id"]]) }
                                Button("Open Conn session") { model.act("conn_open", ["projectId": project["id"]]) }
                                Divider()
                                Button("Move up") { move(project, -1) }.disabled(model.projects.first == project)
                                Button("Move down") { move(project, 1) }.disabled(model.projects.last == project)
                                Button("Delete…", role: .destructive) { deleting = project }
                            } label: { KitIconImage(.more, size: 13).foregroundStyle(.secondary).frame(width: 22, height: 28).contentShape(Rectangle()) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Project actions")
                        }
                    }
                }.disabled(!model.projectsError.isEmpty)
                KitGroup("Agent prompts") {
                    KitRow("All annotations") { Button("Copy prompt") { model.act("copy_prompt", ["scope": .string("all")]) }.buttonStyle(.kit) }
                    KitRow("Unmatched annotations") { Button("Copy inbox prompt") { model.act("copy_prompt", ["scope": .string("inbox")]) }.buttonStyle(.kit) }
                }
            }.frame(maxWidth: Kit.readableWidth).padding(Kit.columnMargin).padding(.bottom, 28).frame(maxWidth: .infinity)
        }.kitBottomFade().kitTopBar {
            PageBar(title: "Projects") {
                KitToolbarGroup { KitToolbarButton(icon: .plus, help: "Add project") { editing = newProject() } }.disabled(!model.projectsError.isEmpty)
            }
        }
        .task { if !model.demo { await model.loadProjects() } }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing { ProjectEditor(model: model, initial: editing) { self.editing = nil } }
        }
        .confirmationDialog("Delete \(deleting?["name"].string ?? "project")? Its annotations stay on the server.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete project", role: .destructive) { let updated = model.projects.filter { $0["id"] != deleting?["id"] }; Task { await saveProjects(model, updated) }; deleting = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoProjectEditor)) { _ in editing = model.projects.first ?? newProject() }
    }
    private func move(_ project: JSON, _ direction: Int) {
        guard let index = model.projects.firstIndex(of: project), model.projects.indices.contains(index + direction) else { return }
        var projects = model.projects; projects.swapAt(index, index + direction); Task { await saveProjects(model, projects) }
    }
}
func newProject() -> JSON { .object(["id": .string(UUID().uuidString.lowercased()), "name": .string(""), "root": .string(""), "bundleIds": .array([]), "titleContains": .array([]), "urlPrefixes": .array([]), "notes": .string(""), "t3Model": .string(""), "t3RuntimeMode": .string("approval-required")]) }
@MainActor func saveProjects(_ model: AppModel, _ projects: [JSON]) async {
    do {
        let result = try await model.call("save_projects", ["routes": .object(["projects": .array(projects)])])
        if result != .null { throw BridgeError(result.string) }
        model.projects = projects
    } catch { model.error = error.localizedDescription }
}
struct ProjectEditor: View {
    @Bindable var model: AppModel
    let initial: JSON
    let dismiss: () -> Void
    @State private var draft: JSON = .null
    @State private var busy = false
    var body: some View {
        KitSheet("Edit project") {
                VStack(spacing: 22) {
                    KitGroup("Project") {
                        KitInputRow("Name", text: text("name"), prompt: "Project name", focusOnAppear: true)
                        KitInputRow("Folder", text: text("root"), prompt: "Choose the project folder") {
                            KitIconButton(.folder, help: "Choose folder") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { draft["root"] = .string(panel.url?.path ?? "") } }
                        }
                    }
                    KitGroup("Routing rules", footer: "One value per line. Window titles ignore case. Bundle IDs and URL prefixes match exactly. Empty groups are ignored.") {
                        KitInputRow("Bundle IDs", text: array("bundleIds"), prompt: "com.apple.Safari", lines: 1...3)
                        KitInputRow("Window titles", text: array("titleContains"), prompt: "Part of a title", lines: 1...3)
                        KitInputRow("URL prefixes", text: array("urlPrefixes"), prompt: "https://example.com", lines: 1...3)
                        KitActionRow("Use last annotated app", icon: .desktop) { Task { do {
                            let last = try await model.call("last_target_app")
                            guard last != .null else { throw BridgeError("Annotate an app first.") }
                            if !last["bundleId"].string.isEmpty { draft["bundleIds"] = .array([last["bundleId"]]) }
                        } catch { model.error = error.localizedDescription } } }
                    }
                    KitGroup("Agent") {
                        KitInputRow("Notes", text: text("notes"), prompt: "Instructions for this project", lines: 2...5)
                        KitInputRow("Model", text: text("t3Model"), prompt: "Use the default model")
                        KitLabeledRow("Runtime mode") { KitPicker(selection: text("t3RuntimeMode"), options: [("full-access", "Full access"), ("approval-required", "Approval required")]) }
                    }
                }
        } actions: {
            Button("Cancel", action: dismiss).buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
            Button("Save") { Task {
                busy = true
                var updated = model.projects
                if let index = updated.firstIndex(where: { $0["id"] == draft["id"] }) { updated[index] = draft } else { updated.append(draft) }
                await saveProjects(model, updated); busy = false; if model.error == nil { dismiss() }
            } }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(busy || draft["name"].string.trimmingCharacters(in: .whitespaces).isEmpty)
        }.frame(width: 560, height: 640).onAppear { draft = initial }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { draft[key].string }, set: { draft[key] = .string($0) }) }
    private func array(_ key: String) -> Binding<String> { Binding(get: { draft[key].array.map(\.string).joined(separator: "\n") }, set: { draft[key] = .array($0.split(separator: "\n").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.string.isEmpty }) }) }
}
extension Notification.Name { static let demoProjectEditor = Notification.Name("demo-project-editor") }
