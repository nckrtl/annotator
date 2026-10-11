import AnnotatorCore
import Foundation
import Observation

/// The projects in `~/.config/annotator/routes.json`. A broken file is reported, never overwritten.
@MainActor @Observable
final class ProjectsStore {
    private(set) var routes = Routes()
    private(set) var error: String?
    let file = Routes.standardFile

    init() {
        reload()
    }

    /// Picks up edits made to the file by hand.
    func reload() {
        do {
            routes = try Routes.load(from: file)
            error = nil
        } catch {
            self.error = "Could not read \(file.path): \(error.localizedDescription) Fix or remove the file."
        }
    }

    func update(_ change: (inout Routes) -> Void) {
        guard error == nil else { return }
        var routes = routes
        change(&routes)
        do {
            try routes.save(to: file)
            self.routes = routes
        } catch {
            self.error = "Could not save \(file.path): \(error.localizedDescription)"
        }
    }

    /// The project name for a new annotation; `Inbox` when none matches.
    func projectName(for target: Target) -> String {
        routes.project(for: target)?.name ?? Project.inbox
    }
}
