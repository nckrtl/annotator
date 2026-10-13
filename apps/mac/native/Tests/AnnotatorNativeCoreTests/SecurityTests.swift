import Foundation
import Testing

@testable import AnnotatorNativeCore

struct SecurityTests {
    @Test func idsMatchTheServerGrammar() {
        #expect(Annotation.isValidID("abc-1"))
        #expect(Annotation.isValidID("a"))
        #expect(!Annotation.isValidID("../secret"))
        #expect(!Annotation.isValidID("foo/bar"))
        #expect(!Annotation.isValidID(""))
        #expect(!Annotation.isValidID("-abc"))
    }

    @Test func debuggingPortComesFromTheLaunchFlag() {
        #expect(DevToolsLaunch.port(in: ["App", "--remote-debugging-port", "9222"]) == 9222)
        #expect(DevToolsLaunch.port(in: ["App", "--remote-debugging-port=9333"]) == 9333)
        #expect(DevToolsLaunch.port(in: ["App", "--remote-debugging-port=nope"]) == nil)
        #expect(DevToolsLaunch.port(in: ["App", "--inspect=9222"]) == nil)
        #expect(DevToolsLaunch.port(in: ["App", "--remote-debugging-port"]) == nil)
    }

    @Test func debuggerSocketStaysOnTheLaunchedPort() {
        #expect(DebuggerEndpoint.socket(from: "ws://127.0.0.1:9222/devtools/page/1", port: 9222) != nil)
        #expect(DebuggerEndpoint.socket(from: "ws://localhost:9222/devtools/page/1", port: 9222) != nil)
        #expect(DebuggerEndpoint.socket(from: "wss://[::1]:9222/devtools/page/1", port: 9222) != nil)
        #expect(DebuggerEndpoint.socket(from: "ws://evil.example:9222/devtools/page/1", port: 9222) == nil)
        #expect(DebuggerEndpoint.socket(from: "ws://127.0.0.1:9333/devtools/page/1", port: 9222) == nil)
        #expect(DebuggerEndpoint.socket(from: "http://127.0.0.1:9222/json", port: 9222) == nil)
    }

    @Test func domDropsSecretAttributes() throws {
        #expect(DOMInfo.redact(#"<input type="password" value="secret" src='x'>"#) == #"<input type="password">"#)
        let info = AXElementInfo(role: "AXSecureTextField", value: "hunter2")
        #expect(info.value == nil)
        let shown = AXElementInfo(role: "AXTextField", value: "hello")
        #expect(shown.value == "hello")
        #expect(try DOMInfo.decode(String(repeating: "x", count: 65_537)) == nil)
    }
}
