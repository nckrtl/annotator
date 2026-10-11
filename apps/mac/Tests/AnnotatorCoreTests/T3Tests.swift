import Foundation
import Testing

@testable import AnnotatorCore

struct T3Tests {
    @Test func controlSocketMatchesTheDesktopApp() {
        // Measured on this Mac: the dev desktop app listens on 386eeb9714d92a2fe2c051a9.sock.
        let instance = T3Instance(home: URL(fileURLWithPath: "/Users/nckrtl/.t3/desktop-dev"))
        let socket = instance.controlSocket(temporaryDirectory: URL(fileURLWithPath: "/tmp/x"), uid: 501)
        #expect(socket.path == "/tmp/x/t3code-501/386eeb9714d92a2fe2c051a9.sock")
        let production = T3Instance(home: URL(fileURLWithPath: "/Users/nckrtl/.t3"))
        #expect(production.controlSocket(temporaryDirectory: URL(fileURLWithPath: "/tmp/x"), uid: 501).lastPathComponent
            == "d9cfc0e3f7eae2d02b72a685.sock")
    }

    @Test func modelText() {
        #expect(T3ModelSelection("codex/gpt-6.1-sol") == T3ModelSelection(instanceId: "codex", model: "gpt-6.1-sol"))
        #expect(T3ModelSelection("codex") == nil)
        #expect(T3ModelSelection(" /x") == nil)
    }

    @Test func snapshotHelpers() throws {
        let json = #"""
        {"snapshotSequence":1,"projects":[
          {"id":"old","title":"t3","workspaceRoot":"/tmp","deletedAt":"2026-01-01T00:00:00Z"},
          {"id":"p1","title":"t3","workspaceRoot":"/tmp/","deletedAt":null}],
         "threads":[
          {"id":"a","projectId":"p1","modelSelection":{"instanceId":"codex","model":"gpt-6-astra"},"updatedAt":"2026-10-07T13:00:00Z","deletedAt":null,
           "session":{"status":"ready","activeTurnId":null}},
          {"id":"b","projectId":"p1","modelSelection":{"instanceId":"codex","model":"gpt-6.1-sol"},"updatedAt":"2026-10-07T20:00:00Z","deletedAt":null,
           "session":{"status":"running","activeTurnId":"t1"}}]}
        """#
        let snapshot = try JSONDecoder().decode(T3Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.project(root: "/tmp")?.id == "p1")
        #expect(snapshot.project(root: "/nowhere") == nil)
        #expect(snapshot.latestModel?.model == "gpt-6.1-sol")
        #expect(snapshot.threads[0].isIdle)
        #expect(!snapshot.threads[1].isIdle)
    }

    @Test func commands() {
        let create = T3Command.createThread(
            id: "t", projectId: "p", title: "Annotations", model: T3ModelSelection(instanceId: "codex", model: "m"),
            runtimeMode: "full-access")
        #expect(create["type"] as? String == "thread.create")
        #expect((create["modelSelection"] as? [String: String])?["model"] == "m")
        #expect(create["worktreePath"] is NSNull)
        let message = T3Command.sendMessage(threadId: "t", text: "Go", runtimeMode: "full-access", titleSeed: "Go")
        #expect(message["type"] as? String == "thread.turn.start")
        #expect((message["message"] as? [String: Any])?["text"] as? String == "Go")
        #expect(T3Command.openThread(environmentId: "e", threadId: "t")["type"] as? String == "open-thread")
        #expect(T3Nudge.text(numbers: [15, 14]).hasPrefix("New annotations for this project: #14, #15."))
    }

    @Test func clientErrors() async {
        let origin = URL(string: "http://127.0.0.1:13775")!
        await #expect(throws: T3Error.unauthorized) {
            try await T3Client(origin: origin, token: "x", transport: stub(status: 401)).snapshot()
        }
        await #expect(throws: T3Error.self) {
            try await T3Client(origin: origin, token: "x", transport: failing).dispatch(["type": "x"])
        }
        let seen = Box<URLRequest>()
        try? await T3Client(origin: origin, token: "secret") { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }.dispatch(["type": "x"])
        #expect(seen.value?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(seen.value?.url?.path == "/api/orchestration/dispatch")
    }
}
