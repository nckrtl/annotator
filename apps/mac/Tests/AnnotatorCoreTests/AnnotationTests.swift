import CoreGraphics
import Foundation
import Testing

@testable import AnnotatorCore

let mailTarget = Target(
    mode: .element,
    app: AppInfo(name: "Mail", bundleId: "com.apple.mail", pid: 812),
    window: WindowInfo(title: "Inbox", id: 4711, frame: CGRect(x: 0, y: 38, width: 1512, height: 944)),
    frame: CGRect(x: 120, y: 340, width: 180, height: 22),
    element: AXElementInfo(role: "AXStaticText", roleDescription: "text", title: "Inbox"),
    path: [
        AXElementInfo(role: "AXWindow", title: "Mail"),
        AXElementInfo(role: "AXSplitGroup"),
        AXElementInfo(role: "AXOutline"),
        AXElementInfo(role: "AXRow"),
        AXElementInfo(role: "AXStaticText", roleDescription: "text", title: "Inbox"),
    ]
)

struct AnnotationTests {
    @Test func labels() {
        #expect(AXElementInfo(role: "AXButton", title: "Save").label == #"AXButton "Save""#)
        #expect(AXElementInfo(role: "AXGroup").label == "AXGroup")
        #expect(AXElementInfo(role: "AXButton", title: "  ", description: "Close").label == #"AXButton "Close""#)
        #expect(AXElementInfo(role: "AXStaticText", value: #"say "hi""#).label == #"AXStaticText "say \"hi\"""#)
    }

    @Test func unnamedWebElements() {
        let row = AXElementInfo(role: "AXGroup", domId: "submodules", domClasses: ["row"], text: "Submodules How new worktrees")
        #expect(row.label == #"AXGroup#submodules "Submodules How new worktrees""#)
        #expect(AXElementInfo(role: "AXGroup", domId: "").label == "AXGroup")
        #expect(AXElementInfo(role: "AXButton", title: "Save", text: "ignored").label == #"AXButton "Save""#)
    }

    @Test func valueIsTruncated() {
        let info = AXElementInfo(role: "AXTextArea", value: String(repeating: "x", count: 500))
        #expect(info.value?.count == AXElementInfo.maxValueLength)
        #expect(info.value?.hasSuffix("…") == true)
    }

    @Test func encodesTheBriefRecord() throws {
        let annotation = Annotation(
            id: "6f1c0000-0000-4000-8000-000000000000",
            timestamp: Date(timeIntervalSince1970: 1_791_400_000),
            comment: "The sidebar title is clipped",
            target: mailTarget,
            screenSize: CGSize(width: 3024, height: 1964),
            screenshot: "data:image/jpeg;base64,AAAA"
        )
        let json = try #require(JSONSerialization.jsonObject(with: annotation.encoded()) as? [String: Any])
        let expected: [String: Any] = [
            "id": "6f1c0000-0000-4000-8000-000000000000",
            "timestamp": 1_791_400_000_000,
            "comment": "The sidebar title is clipped",
            "element": #"AXStaticText "Inbox""#,
            "elementPath": #"AXWindow "Mail" > AXSplitGroup > AXOutline > AXRow > AXStaticText "Inbox""#,
            "url": "app://com.apple.mail",
            "pathname": "Mail — Inbox",
            "boundingBox": ["x": 120, "y": 340, "width": 180, "height": 22],
            "screenSize": "3024px, 1964px",
            "screenshot": "data:image/jpeg;base64,AAAA",
            "native": [
                "app": ["name": "Mail", "bundleId": "com.apple.mail", "pid": 812],
                "window": ["title": "Inbox", "id": 4711, "frame": ["x": 0, "y": 38, "width": 1512, "height": 944]],
                "ax": [
                    "role": "AXStaticText", "subrole": NSNull(), "roleDescription": "text",
                    "title": "Inbox", "description": NSNull(), "identifier": NSNull(), "value": NSNull(),
                    "domId": NSNull(), "domClasses": [String](), "text": NSNull(),
                    "path": [#"AXWindow "Mail""#, "AXSplitGroup", "AXOutline", "AXRow", #"AXStaticText "Inbox""#],
                ],
                "webUrl": NSNull(),
                "mode": "element",
                "project": NSNull(),
                "dom": NSNull(),
            ],
        ]
        #expect(NSDictionary(dictionary: json).isEqual(to: expected))
    }

    @Test func domFieldsMatchTheWebAnnotator() throws {
        let json = #"""
        {"name":"button \"Save\"","path":".settings-row > button","tag":"button","selector":"div#root > button:nth-of-type(2)",
         "html":"<button class=\"px-3\"> Save","rect":{"x":10,"y":20,"width":80,"height":24},
         "component":"src/settings/Row.tsx:42","react":"<Settings> <Row>",
         "components":[{"name":"Row","file":"src/settings/Row.tsx","line":42},{"name":"Settings"}],
         "appearance":{"classes":["px-3"],"computed":{"fontSize":"14px"},"utilities":{"padding":"px-3"}}}
        """#
        let dom = try #require(try DOMInfo.decode(json))
        #expect(dom.screenFrame(viewport: CGRect(x: 100, y: 50, width: 800, height: 600)) == CGRect(x: 110, y: 70, width: 80, height: 24))
        var target = mailTarget
        target.dom = dom
        let annotation = Annotation(comment: "x", target: target, screenSize: .zero, screenshot: nil)
        #expect(annotation.element == #"button "Save""#)
        #expect(annotation.elementPath == ".settings-row > button")
        #expect(annotation.component == "src/settings/Row.tsx:42")
        #expect(annotation.react == "<Settings> <Row>")
        #expect(annotation.components?.count == 2)
        #expect(annotation.appearance?.utilities["padding"] == "px-3")
        #expect(annotation.native.dom?.selector == "div#root > button:nth-of-type(2)")
        #expect(annotation.native.ax?.role == "AXStaticText")
        #expect(try DOMInfo.decode("null") == nil)
    }

    @Test func pickDevToolsPage() {
        func page(_ url: String, _ title: String = "") -> DevToolsTargets.Target {
            .init(type: "page", url: url, title: title, webSocketDebuggerUrl: "ws://x/\(url)")
        }
        let worker = DevToolsTargets.Target(type: "service_worker", url: "a", title: nil, webSocketDebuggerUrl: "ws://w")
        #expect(DevToolsTargets.pick([page("t3code://app/"), page("t3code://other"), worker], url: "t3code://app")?.url == "t3code://app/")
        #expect(DevToolsTargets.pick([page("a", "One"), page("a", "Two")], url: "a", title: "Two")?.title == "Two")
        #expect(DevToolsTargets.pick([page("a"), page("a")], url: "a") == nil)
        #expect(DevToolsTargets.pick([page("only")], url: nil)?.url == "only")
        #expect(DevToolsTargets.pick([page("one"), page("two")], url: "three") == nil)
        let devtools = page("devtools://devtools/bundled/devtools_app.html")
        let tab = DevToolsTargets.Target(type: "webview", url: "http://localhost:8000/", title: "Shop", webSocketDebuggerUrl: "ws://tab")
        #expect(DevToolsTargets.pick([page("t3code-dev://app/"), tab, devtools], url: "http://localhost:8000/")?.type == "webview")
        #expect(DevToolsTargets.pick([page("t3code-dev://app/"), devtools], url: "t3code-dev://app/#/draft/1")?.url == "t3code-dev://app/")
        #expect(DevToolsTargets.pick([page("t3code-dev://app/"), devtools], url: nil)?.url == "t3code-dev://app/")
    }

    @Test func webContentUsesThePageURL() {
        var target = mailTarget
        target.webUrl = "https://example.com/page"
        let annotation = Annotation(comment: "x", target: target, screenSize: .zero, screenshot: nil)
        #expect(annotation.url == "https://example.com/page")
        #expect(annotation.native.webUrl == "https://example.com/page")
    }

    @Test func windowFallbackIsLabeled() throws {
        var target = mailTarget
        target.mode = .window
        target.element = nil
        target.path = []
        let annotation = Annotation(comment: "x", target: target, screenSize: .zero, screenshot: nil)
        #expect(annotation.element == #"AXWindow "Inbox""#)
        #expect(annotation.native.mode == .window)
        let json = try #require(JSONSerialization.jsonObject(with: annotation.encoded()) as? [String: Any])
        let native = try #require(json["native"] as? [String: Any])
        #expect(native["ax"] is NSNull)
        #expect(native["mode"] as? String == "window")
    }

    @Test func idIsAValidLowercaseUUID() {
        let id = Annotation(comment: "x", target: mailTarget, screenSize: .zero, screenshot: nil).id
        #expect(id == id.lowercased())
        #expect(id.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_-]{0,199}/) != nil)
    }
}
