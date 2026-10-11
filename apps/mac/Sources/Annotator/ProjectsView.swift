import Inject
import AnnotatorCore
import AppKit
import SwiftUI

/// Settings › Projects: which windows belong to which project, where its code lives, and notes for agents.
struct ProjectsView: View {
    @ObserveInjection var injection
    let store: ProjectsStore
    /// The app and window of the last annotation, to fill in rules quickly.
    let lastTarget: () -> Target?
    @State private var selection: String?

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.error {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Read the file again") { store.reload() }
                }
                HStack(alignment: .top, spacing: 16) {
                    list
                    if let index = store.routes.projects.firstIndex(where: { $0.id == selection }) {
                        editor(index)
                    } else {
                        Text(store.routes.projects.isEmpty
                            ? "Add a project to route annotations to their own agent session."
                            : "Select a project.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Text("Annotations that match no project go to \(Project.inbox). The first matching project wins. Saved in \(store.file.path).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 640, height: 560)
            .onAppear {
                store.reload()
                selection = selection ?? store.routes.projects.first?.id
            }
        }
        .enableInjection()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(store.routes.projects) { project in
                    Text(project.name.isEmpty ? "Untitled" : project.name).tag(project.id)
                }
                .onMove { from, to in store.update { $0.projects.move(fromOffsets: from, toOffset: to) } }
            }
            .frame(width: 180)
            HStack(spacing: 4) {
                Button {
                    let project = Project(name: "New project")
                    store.update { $0.projects.append(project) }
                    selection = project.id
                } label: { Image(systemName: "plus") }
                Button {
                    guard let selection else { return }
                    store.update { $0.projects.removeAll { $0.id == selection } }
                    self.selection = store.routes.projects.first?.id
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
        }
        .disabled(store.error != nil)
    }

    private func editor(_ index: Int) -> some View {
        let project = Binding(
            get: { store.routes.projects[index] },
            set: { value in store.update { $0.projects[index] = value } })
        return Form {
            TextField("Name", text: project.name)
            HStack {
                TextField("Folder", text: project.root, prompt: Text("~/apps/my-project"))
                Button("Choose…") { chooseFolder(project) }
            }
            ListField(label: "Bundle ids", prompt: "com.example.app", values: project.bundleIds)
            ListField(label: "Window title contains", prompt: "Settings", values: project.titleContains)
            ListField(label: "URL starts with", prompt: "http://localhost:5733/", values: project.urlPrefixes)
            if let target = lastTarget() {
                Button("Use \(target.app.name) from the last annotation") {
                    if let bundleId = target.app.bundleId { project.wrappedValue.bundleIds = [bundleId] }
                }
            }
            Text("Separate several values with commas. Each kind you fill in must match. A Conn model reads like codex/gpt-6.1-sol.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Conn model", text: project.t3Model, prompt: Text("The default model from General"))
            Picker("Conn permissions", selection: project.t3RuntimeMode) {
                ForEach(Project.runtimeModes, id: \.self) { Text($0).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes for the agent")
                TextEditor(text: project.notes)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                Text("How to run the app, where the code is, which checks to run. Added to the copied prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .disabled(store.error != nil)
        // A fresh editor per project, so drafts never carry over to the next one.
        .id(store.routes.projects[index].id)
    }

    private func chooseFolder(_ project: Binding<Project>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { project.wrappedValue.root = url.path }
    }
}

/// A list of strings edited as one comma-separated field. Saved on Return or when the field loses focus,
/// so a half-typed value is not cleaned up while typing.
private struct ListField: View {
    @ObserveInjection var injection
    let label: String
    let prompt: String
    @Binding var values: [String]
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            TextField(label, text: $draft, prompt: Text(prompt))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { draft = values.joined(separator: ", ") }
                .onChange(of: values) { _, new in if !focused { draft = new.joined(separator: ", ") } }
        }
        .enableInjection()
    }

    private func commit() {
        let parsed = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != values { values = parsed }
        draft = parsed.joined(separator: ", ")
    }
}
