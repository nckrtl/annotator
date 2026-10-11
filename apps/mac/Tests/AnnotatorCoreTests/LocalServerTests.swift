import Foundation
import Testing
@testable import AnnotatorCore

struct LocalServerTests {
    @Test func opusMediumCommand() throws {
        let command = T3Command.createThread(id: "t", projectId: "p", title: "Annotations",
            model: T3ModelSelection("claudeAgent/claude-opus-5-5")!, runtimeMode: "full-access", effort: "medium")
        let selection = try #require(command["modelSelection"] as? [String: Any])
        #expect(selection["model"] as? String == "claude-opus-5-5")
        #expect(selection["options"] as? [[String: String]] == [["id": "effort", "value": "medium"]])
    }

    @Test func onlyLocalAnnotationEndpoints() {
        for value in ["https://127.0.0.1:29703/annotations", "http://example.com/annotations", "http://127.0.0.1/other", "http://localhost/annotations?x=1"] {
            #expect(LocalServer(url: URL(string: value)!) == nil)
        }
        #expect(LocalServer(url: URL(string: "http://localhost:29703/annotations")!)?.port == 29703)
    }

    @Test func serverLifecycle() async throws {
        let files = FileManager.default
        let realHome = files.homeDirectoryForCurrentUser
        let home = files.temporaryDirectory.appending(path: "annotator-lifecycle-\(UUID().uuidString)")
        try files.createDirectory(at: home.appending(path: "apps"), withIntermediateDirectories: true)
        try files.createDirectory(at: home.appending(path: ".vite-plus/bin"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: home.appending(path: "apps/annotator"), withDestinationURL: realHome.appending(path: "apps/annotator"))
        try files.createSymbolicLink(at: home.appending(path: ".vite-plus/bin/node"), withDestinationURL: realHome.appending(path: ".vite-plus/bin/node"))
        let server = LocalServer(url: URL(string: "http://127.0.0.1:39743/annotations")!, home: home)!
        do {
            #expect(try await !server.run("status").running)
            #expect(try await server.run("start").running)
            #expect(try await server.run("status").running)
            // Repeated start keeps the same server and store.
            let first = try Data(contentsOf: server.state)
            #expect(try await server.run("start").running)
            #expect(try Data(contentsOf: server.state) == first)
            #expect(try await !server.run("stop").running)
            #expect(try await !server.run("status").running)
            #expect(try await server.run("start").running)
            #expect(try await !server.run("stop").running)
            try files.removeItem(at: home)
        } catch {
            _ = try? await server.run("stop")
            try? files.removeItem(at: home)
            throw error
        }
    }
}
