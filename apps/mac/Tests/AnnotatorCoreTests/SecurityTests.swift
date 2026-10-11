import Foundation
import Testing

@testable import AnnotatorCore

struct SecurityTests {
    @Test func serviceURLRejectsUserinfoAndCleartextOffBox() {
        #expect(ServiceURL.parse("http://127.0.0.1:29703@attacker.example/annotations") == nil)
        #expect(ServiceURL.parse("http://example.com/annotations") == nil)
        #expect(ServiceURL.parse("http://127.0.0.1:29703/annotations?x=1") == nil)
        #expect(ServiceURL.parse("http://127.0.0.1:29703/annotations#frag") == nil)
        #expect(ServiceURL.parse("http://127.0.0.1:29703/annotations")?.host() == "127.0.0.1")
        #expect(ServiceURL.parse("https://example.com/annotations")?.host() == "example.com")
        #expect(ServiceURL.parse("http://localhost:29703/annotations") != nil)
        #expect(ServiceURL.loopback("https://example.com/annotations") == nil)
        #expect(ServiceURL.loopback("http://[::1]:12321")?.host() == "::1")
        #expect(ServiceURL.loopback("https://127.0.0.1:12321") != nil)
    }

    @Test func idsMatchTheServerGrammar() {
        #expect(Annotation.isValidID("abc-1"))
        #expect(Annotation.isValidID("a"))
        #expect(!Annotation.isValidID("../secret"))
        #expect(!Annotation.isValidID("foo/bar"))
        #expect(!Annotation.isValidID(""))
        #expect(!Annotation.isValidID("-abc"))
    }

    @Test func redactorNullsScreenshotStringsOnly() {
        let input = Data(#"{"note":"see \"screenshot\"","screenshot":"HUGE","count":1,"nested":{"screenshot":"also"}}"#.utf8)
        let output = String(decoding: JSONRedactor.nullifyStrings(named: ["screenshot"], in: input), as: UTF8.self)
        #expect(output == #"{"note":"see \"screenshot\"","screenshot":null,"count":1,"nested":{"screenshot":null}}"#)
        let number = Data(#"{"screenshot":1}"#.utf8)
        #expect(JSONRedactor.nullifyStrings(named: ["screenshot"], in: number) == number)
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

    @Test func pairingBinaryMustLiveInApplications() {
        let script = "/Applications/AnnotatorTrustTest.app/Contents/Resources/app.asar/apps/server/dist/bin.mjs"
        #expect(AppBundleTrust.installed(
            executable: "/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn", script: script))
        #expect(!AppBundleTrust.installed(
            executable: "/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn", script: "/tmp/bin.mjs"))
        #expect(!AppBundleTrust.installed(
            executable: "/Users/me/Conn.app/Contents/MacOS/Conn",
            script: "/Users/me/Conn.app/Contents/Resources/bin.mjs"))
        #expect(AppBundleTrust.application(containing: "/Applications/AnnotatorTrustTest.app/Contents/MacOS/Conn")
            == "/Applications/AnnotatorTrustTest.app")
    }
}
