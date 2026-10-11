import AnnotatorCore
import AppKit
import Testing
@testable import Annotator

@Suite(.serialized)
@MainActor
struct CommentCancellationTests {
    @Test(arguments: [CommentModel.Dictation.recording, .transcribing])
    func closesBeforeOfideAnswers(_ state: CommentModel.Dictation) async throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let model = CommentModel(target: Target(
            mode: .window, app: AppInfo(name: "Test", bundleId: nil, pid: 0),
            window: WindowInfo(title: "Test", id: 0, frame: frame), frame: frame))
        model.dictation = state
        let panel = CommentPanelController(model: model)
        let requests = Requests()
        panel.ofide = .success(OfideClient(base: URL(string: "http://127.0.0.1:12322")!, token: "test") { request in
            await requests.record(request.url!.path)
            try await Task.sleep(for: .milliseconds(300))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        })
        var closes = 0
        panel.onClose = { closes += 1 }
        panel.close()
        // These must be true synchronously, before the delayed HTTP request completes.
        #expect(closes == 1)
        #expect(model.dictation == .off)
        panel.close()
        #expect(closes == 1)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await requests.paths == ["/dictate/cancel"])
        #expect(model.dictation == .off)
    }
}

private actor Requests {
    var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}
