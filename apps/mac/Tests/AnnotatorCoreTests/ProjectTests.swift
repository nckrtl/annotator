import Foundation
import Testing

@testable import AnnotatorCore

struct ProjectTests {
    let t3 = Project(
        name: "T3 Code Dev", root: "/Users/me/apps/t3code", bundleIds: ["com.t3tools.t3code.dev.t3code"],
        notes: "Run with T3CODE_DESKTOP_REMOTE_DEBUGGING_PORT=9222 pnpm dev:desktop.")
    let settings = Project(name: "T3 Settings", bundleIds: ["com.t3tools.t3code.dev.t3code"], titleContains: ["settings"])
    let docs = Project(name: "Docs", urlPrefixes: ["https://docs.example.com/"])

    @Test func rulesOfEachKindMustAllMatch() {
        #expect(settings.matches(bundleId: "com.t3tools.t3code.dev.t3code", title: "T3 — Settings", url: nil))
        #expect(!settings.matches(bundleId: "com.t3tools.t3code.dev.t3code", title: "Chat", url: nil))
        #expect(!settings.matches(bundleId: "com.apple.finder", title: "Settings", url: nil))
        #expect(docs.matches(bundleId: "com.google.Chrome", title: nil, url: "https://docs.example.com/a"))
        #expect(!Project(name: "Empty").matches(bundleId: "x", title: "x", url: "x"))
    }

    @Test func firstMatchWins() {
        let routes = Routes(projects: [settings, t3, docs])
        #expect(routes.project(bundleId: "com.t3tools.t3code.dev.t3code", title: "Settings", url: nil)?.name == "T3 Settings")
        #expect(routes.project(bundleId: "com.t3tools.t3code.dev.t3code", title: "Chat", url: nil)?.name == "T3 Code Dev")
        #expect(routes.project(bundleId: "com.apple.mail", title: nil, url: nil) == nil)
    }

    @Test func fileRoundTripAndBrokenFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "routes-\(UUID().uuidString)/routes.json")
        #expect(try Routes.load(from: file) == Routes())
        try Routes(projects: [t3]).save(to: file)
        #expect(try Routes.load(from: file).projects == [t3])
        try Data("{ not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try Routes.load(from: file) }
    }

    @Test func minimalFileLoads() throws {
        let routes = try JSONDecoder().decode(Routes.self, from: Data(#"{"projects":[{"name":"Shop","urlPrefixes":["http://localhost:8000/"]}]}"#.utf8))
        #expect(routes.projects[0].t3RuntimeMode == "approval-required")
        #expect(routes.projects[0].root == "")
        #expect(!routes.projects[0].id.isEmpty)
    }

    @Test func recordCarriesTheProject() {
        let annotation = Annotation(comment: "x", target: mailTarget, screenSize: .zero, screenshot: nil, project: "Docs")
        #expect(annotation.native.project == "Docs")
    }

    @Test func projectPrompt() {
        let prompt = AgentPrompt.make(server: "http://127.0.0.1:29703/annotations", scope: .project(t3))
        #expect(prompt.contains("ANNOTATIONS_URL='http://127.0.0.1:29703/annotations'"))
        #expect(prompt.contains("PROJECT_ROOT='/Users/me/apps/t3code'"))
        #expect(prompt.contains("PROJECT_NAME='T3 Code Dev'"))
        #expect(prompt.contains(#"jq --arg project "$PROJECT_NAME""#))
        #expect(prompt.contains("select(.native.project == $project)"))
        #expect(prompt.contains("Never claim without an id"))
        #expect(prompt.hasSuffix("Run with T3CODE_DESKTOP_REMOTE_DEBUGGING_PORT=9222 pnpm dev:desktop."))
        #expect(!prompt.contains("\n\n\n"))
    }

    @Test func allPromptHasNoFilter() {
        let prompt = AgentPrompt.make(server: "http://x/annotations", scope: .all)
        #expect(!prompt.contains("native.project =="))
        #expect(!prompt.contains("PROJECT_ROOT"))
        #expect(AgentPrompt.make(server: "http://x/annotations", scope: .inbox).contains("PROJECT_NAME='Inbox'"))
        #expect(AgentPrompt.make(server: "http://x/annotations", scope: .inbox).contains("select(.native.project == $project)"))
    }

    @Test func promptQuotesStayData() {
        let odd = Project(name: "Nick's \"App\"", root: "/tmp/a'b")
        let prompt = AgentPrompt.make(server: "http://127.0.0.1:29703/annotations", scope: .project(odd))
        #expect(prompt.contains("PROJECT_ROOT='/tmp/a'\\''b'"))
        #expect(prompt.contains("PROJECT_NAME='Nick'\\''s \"App\"'"))
        #expect(!prompt.contains("select(.native.project == \"Nick"))
    }
}
