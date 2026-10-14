import Foundation
import Testing
import AnnotatorNativeCore
@testable import AnnotatorNative

private actor Probe {
    var calls = 0
    let readyOn: Int
    let warming: Bool
    init(readyOn: Int, warming: Bool = true) { self.readyOn = readyOn; self.warming = warming }
    func read() -> (Target?, Bool) {
        calls += 1
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        return (Target(mode: .window, app: AppInfo(name: "Fixture", bundleId: nil, pid: 1),
            window: WindowInfo(title: nil, id: 1, frame: frame), frame: frame,
            webArea: calls >= readyOn ? frame : nil), warming)
    }
}

@Test func firstElectronSelectionWaitsForItsWebArea() async {
    let probe = Probe(readyOn: 3)
    let target = await AXReader.waitForWebArea(text: true) { await probe.read() }
    #expect(target?.webArea != nil)
    #expect(await probe.calls == 3)
}

@Test func hoverAndOldAccessibilityRequestsDoNotWait() async {
    for (text, warming) in [(false, true), (true, false)] {
        let probe = Probe(readyOn: 100, warming: warming)
        let target = await AXReader.waitForWebArea(text: text) { await probe.read() }
        #expect(target?.webArea == nil)
        #expect(await probe.calls == 1)
    }
}

@Test func missingWebAreaKeepsWindowFallbackWithinDeadline() async {
    let probe = Probe(readyOn: 100)
    let start = ContinuousClock.now
    let target = await AXReader.waitForWebArea(text: true) { await probe.read() }
    #expect(target?.mode == .window)
    #expect(await probe.calls <= 8)
    #expect(start.duration(to: .now) < .seconds(1))
}
