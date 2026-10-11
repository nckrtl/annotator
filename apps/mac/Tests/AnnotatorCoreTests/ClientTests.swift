import Foundation
import Testing

@testable import AnnotatorCore

func stub(status: Int, body: String = "") -> HTTPTransport {
    { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

let failing: HTTPTransport = { _ in throw URLError(.cannotConnectToHost) }
let base = URL(string: "http://127.0.0.1:29703/annotations")!

struct AnnotationClientTests {
    func post(_ transport: @escaping HTTPTransport) async -> PostResult {
        await AnnotationClient(base: base, transport: transport)
            .post(Annotation(comment: "x", target: mailTarget, screenSize: .zero, screenshot: nil))
    }

    @Test func created() async {
        let result = await post(stub(status: 201, body: #"{"data":{"number":7}}"#))
        #expect(result == .created(number: 7))
        #expect(result.isStored && !result.isRetryable)
    }

    @Test func existingOnRetry() async {
        let result = await post(stub(status: 200, body: #"{"data":{"number":7}}"#))
        #expect(result == .existing(number: 7))
        #expect(result.isStored)
    }

    @Test func deletedIsNotResent() async {
        let result = await post(stub(status: 410, body: #"{"error":"Annotation was removed"}"#))
        #expect(result == .deleted)
        #expect(!result.isStored && !result.isRetryable)
    }

    @Test func tooLargeIsNotResent() async {
        let result = await post(stub(status: 413, body: #"{"error":"Annotation exceeds 10 MiB"}"#))
        #expect(result == .tooLarge)
        #expect(!result.isRetryable)
    }

    @Test func serverErrorIsRetried() async {
        let result = await post(stub(status: 500, body: #"{"error":"Could not process annotation"}"#))
        #expect(result == .serverError(status: 500, message: "Could not process annotation"))
        #expect(result.isRetryable)
    }

    @Test func otherClientErrorIsRejected() async {
        let result = await post(stub(status: 422, body: #"{"error":"id and comment are required"}"#))
        #expect(result == .rejected(status: 422, message: "id and comment are required"))
        #expect(!result.isRetryable)
    }

    @Test func connectionFailureIsRetried() async {
        let result = await post(failing)
        guard case .unreachable = result else { Issue.record("expected unreachable, got \(result)"); return }
        #expect(result.isRetryable)
    }

    @Test func postSendsJSON() async {
        let seen = Box<URLRequest>()
        _ = await post { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        #expect(seen.value?.httpMethod == "POST")
        #expect(seen.value?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(seen.value?.url == base)
    }

    @Test func deleteOne() async {
        let seen = Box<URLRequest>()
        let ok = await AnnotationClient(base: base) { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }.delete(id: "abc-1")
        #expect(ok)
        #expect(seen.value?.httpMethod == "DELETE")
        #expect(seen.value?.url?.absoluteString == "http://127.0.0.1:29703/annotations/abc-1")
        #expect(await AnnotationClient(base: base, transport: stub(status: 404)).delete(id: "gone"))
        #expect(await !AnnotationClient(base: base, transport: stub(status: 500)).delete(id: "x"))
        #expect(await !AnnotationClient(base: base, transport: failing).delete(id: "x"))
    }

    @Test func deleteRejectsPathIds() async {
        let seen = Box<URLRequest>()
        let client = AnnotationClient(base: base) { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await !client.delete(id: "../secret"))
        #expect(await !client.delete(id: "foo/bar"))
        #expect(seen.value == nil)
    }

    @Test func queueDropsScreenshots() async throws {
        let body = #"""
        {"data":[{"id":"a","number":1,"status":"todo","comment":"x","screenshot":"data:image/jpeg;base64,AAAA"}],
         "meta":{"service":"@nckrtl/annotator"}}
        """#
        let client = AnnotationClient(base: base, transport: stub(status: 200, body: body))
        let summary = try await client.queue()
        #expect(summary.item(id: "a")?.screenshot == nil)
        #expect(await client.screenshot(id: "a") == "data:image/jpeg;base64,AAAA")
        #expect(await client.screenshot(id: "../secret") == nil)
    }

    @Test func queueSummary() async throws {
        let body = #"""
        {"data":[
          {"id":"a","number":1,"status":"done","comment":"one"},
          {"id":"b","number":3,"status":"todo","comment":"three"},
          {"id":"c","number":2,"status":"in_progress","comment":"two"}
        ],"meta":{"service":"@nckrtl/annotator","lastNumber":3}}
        """#
        let summary = try await AnnotationClient(base: base, transport: stub(status: 200, body: body)).queue()
        #expect((summary.todo, summary.inProgress, summary.done) == (1, 1, 1))
        #expect(summary.open.map(\.number) == [2, 3])
        #expect(summary.finished.map(\.number) == [1])
        #expect(summary.item(id: "c")?.isInProgress == true)
    }

    @Test func queueReadsFullRecords() async throws {
        let body = #"""
        {"data":[{"id":"a","number":4,"status":"todo","question":true,"summary":"Which button?","comment":"x",
          "element":"AXButton \"Save\"","boundingBox":{"x":1,"y":2,"width":3,"height":4},
          "native":{"app":{"name":"Mail","bundleId":"com.apple.mail","pid":1},"mode":"element","window":{"title":"Inbox","id":7}}},
          {"id":"b","status":"done","comment":"from the web annotator"}],
         "meta":{"service":"@nckrtl/annotator"}}
        """#
        let summary = try await AnnotationClient(base: base, transport: stub(status: 200, body: body)).queue()
        let item = try #require(summary.item(id: "a"))
        #expect(item.needsAnswer)
        #expect(item.native?.app?.name == "Mail")
        #expect(item.boundingBox?.width == 3)
        #expect(summary.item(id: "b")?.native == nil)
    }

    @Test func queueRejectsOtherServers() async {
        await #expect(throws: QueueError.notAnnotationServer) {
            try await AnnotationClient(base: base, transport: stub(status: 200, body: #"{"data":[]}"#)).queue()
        }
    }
}

struct OfideClientTests {
    let ofide = URL(string: "http://127.0.0.1:12321")!

    @Test func statusCodes() async {
        #expect(await OfideClient(base: ofide, token: "t", transport: stub(status: 200)).stop() == .ok)
        #expect(await OfideClient(base: ofide, token: "t", transport: stub(status: 409)).stop() == .noDictation)
        #expect(await OfideClient(base: ofide, token: "t", transport: stub(status: 422)).stop() == .silence)
        #expect(await OfideClient(base: ofide, token: "t", transport: stub(status: 504)).stop() == .failed("504 gateway timed out"))
        #expect(await OfideClient(base: ofide, token: "t", transport: failing).start() == .notRunning)
        #expect(await OfideClient(base: ofide, token: "t", transport: stub(status: 401)).status() == .unauthorized)
    }

    @Test func paths() async {
        let seen = Box<URLRequest>()
        let transport: HTTPTransport = { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        }
        _ = await OfideClient(base: ofide, token: "t", transport: transport).start()
        #expect(seen.value?.url?.absoluteString == "http://127.0.0.1:12321/dictate/start")

        _ = await OfideClient(base: ofide, token: "t", transport: transport).stop()
        #expect(seen.value?.url?.absoluteString == "http://127.0.0.1:12321/dictate-stop")
        #expect(seen.value?.httpMethod == "POST")
        #expect(seen.value?.value(forHTTPHeaderField: "X-Ofide-Token") == "t")
    }

    @Test func state() async {
        let client = OfideClient(base: ofide, token: "t", transport: stub(status: 200, body: #"{"status":"transcribing","queued":false}"#))
        #expect(await client.state() == "transcribing")
        #expect(await OfideClient(base: ofide, token: "t", transport: failing).state() == nil)
    }

    @Test func cancelUsesTheNonPastingEndpoint() async {
        let seen = Box<URLRequest>()
        let client = OfideClient(base: ofide, token: "t", transport: { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        })
        #expect(await client.cancel() == .ok)
        #expect(seen.value?.url?.path == "/dictate/cancel")
        #expect(seen.value?.httpMethod == "POST")
        #expect(seen.value?.timeoutInterval == 3)
        #expect(seen.value?.value(forHTTPHeaderField: "X-Ofide-Token") == "t")
    }

    @Test func readsCancellationAlongsideOfideState() async {
        let client = OfideClient(base: ofide, token: "t", transport: stub(status: 200, body: #"{"status":"ready","cancelledAt":1791400000000}"#))
        let state = await client.snapshot()
        #expect(state?.status == "ready")
        #expect(state?.cancelledAt == 1791400000000)
    }

    @Test func readsTheToken() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ofide-\(UUID().uuidString)")
        let file = OfideToken.file(bundleId: "com.nckrtl.ofide", home: home)
        #expect(throws: OfideToken.Failure.missing(file.path)) { try OfideToken.read(file) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"token":"abc"}"#.utf8).write(to: file)
        #expect(try OfideToken.read(file) == "abc")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
}
