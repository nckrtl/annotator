import CoreGraphics
import Testing

@testable import AnnotatorNativeCore

struct FrozenElementsTests {
    let menu = CGRect(x: 216, y: 31, width: 193, height: 307)

    func target(_ frame: CGRect) -> Target {
        Target(
            mode: .element, app: AppInfo(name: "Device Hub", bundleId: nil, pid: 1),
            window: WindowInfo(title: nil, id: 7, frame: menu), frame: frame)
    }

    @Test func smallestElementWins() {
        let item = CGRect(x: 216, y: 237, width: 193, height: 24)
        let frozen = FrozenElements(windows: [menu], targets: [target(menu), target(item)])
        #expect(frozen.target(at: CGPoint(x: 245, y: 245))?.frame == item)
        #expect(frozen.target(at: CGPoint(x: 245, y: 100))?.frame == menu)
    }

    @Test func namedElementWinsATie() {
        let item = CGRect(x: 326, y: 167, width: 195, height: 24)
        var hidden = target(item)
        hidden.element = AXElementInfo(role: "AXMenuItem", title: "")
        var visible = target(item)
        visible.element = AXElementInfo(role: "AXMenuItem", title: "Rotate Left")
        let frozen = FrozenElements(windows: [menu], targets: [hidden, visible])
        #expect(frozen.target(at: CGPoint(x: 400, y: 170))?.element?.title == "Rotate Left")
    }

    @Test func onlyRecordedWindowsCount() {
        let frozen = FrozenElements(windows: [menu], targets: [target(menu)])
        #expect(frozen.covers(CGPoint(x: 300, y: 100)))
        #expect(!frozen.covers(CGPoint(x: 600, y: 600)))
        #expect(frozen.target(at: CGPoint(x: 600, y: 600)) == nil)
    }

    @Test func pixelRectScalesAndClips() {
        let size = CGSize(width: 3024, height: 1964)
        #expect(Geometry.pixelRect(of: CGRect(x: 10, y: 20, width: 100, height: 50), scale: 2, imageSize: size)
            == CGRect(x: 20, y: 40, width: 200, height: 100))
        #expect(Geometry.pixelRect(of: CGRect(x: 1500, y: 970, width: 50, height: 50), scale: 2, imageSize: size)
            == CGRect(x: 3000, y: 1940, width: 24, height: 24))
        #expect(Geometry.pixelRect(of: CGRect(x: 2000, y: 0, width: 10, height: 10), scale: 2, imageSize: size) == nil)
    }
}
