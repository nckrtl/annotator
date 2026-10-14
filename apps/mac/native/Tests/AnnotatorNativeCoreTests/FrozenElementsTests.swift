import CoreGraphics
import Testing

@testable import AnnotatorNativeCore

struct FrozenElementsTests {
    let menu = CGRect(x: 216, y: 31, width: 193, height: 307)
    let main = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func target(_ frame: CGRect, title: String? = nil, window: CGRect? = nil) -> Target {
        Target(
            mode: .element, app: AppInfo(name: "Device Hub", bundleId: nil, pid: 1),
            window: WindowInfo(title: nil, id: 7, frame: window ?? menu), frame: frame,
            element: AXElementInfo(role: "AXMenuItem", title: title))
    }

    func mapped(_ lookup: FrozenElements.Lookup) -> Target? {
        if case .mapped(let target, _) = lookup { return target }
        return nil
    }

    @Test func smallestElementWins() {
        let item = CGRect(x: 216, y: 237, width: 193, height: 24)
        let frozen = FrozenElements(windows: [
            FrozenWindow(id: 7, frame: menu, target: target(menu), elements: [target(menu), target(item)])
        ])
        #expect(mapped(frozen.lookup(CGPoint(x: 245, y: 245)))?.frame == item)
        #expect(mapped(frozen.lookup(CGPoint(x: 245, y: 100)))?.frame == menu)
    }

    @Test func namedElementWinsATie() {
        let item = CGRect(x: 326, y: 167, width: 195, height: 24)
        let frozen = FrozenElements(windows: [
            FrozenWindow(
                id: 7, frame: menu, target: target(menu),
                elements: [target(item, title: ""), target(item, title: "Rotate Left")])
        ])
        #expect(mapped(frozen.lookup(CGPoint(x: 400, y: 170)))?.element?.title == "Rotate Left")
    }

    @Test func frontmostWindowDecides() {
        // A small button of the window behind sits under the menu: the menu still wins.
        let button = CGRect(x: 230, y: 100, width: 20, height: 20)
        let frozen = FrozenElements(windows: [
            FrozenWindow(id: 7, frame: menu, target: target(menu), elements: [target(menu)]),
            FrozenWindow(id: 8, frame: main, target: target(main, window: main), elements: [target(button, window: main)]),
        ])
        #expect(mapped(frozen.lookup(CGPoint(x: 240, y: 110)))?.frame == menu)
        #expect(mapped(frozen.lookup(CGPoint(x: 600, y: 600)))?.frame == main)
    }

    @Test func unmappedWindowsStayLive() {
        let other = CGRect(x: 500, y: 500, width: 300, height: 200)
        let frozen = FrozenElements(windows: [
            FrozenWindow(id: 9, frame: other),
            FrozenWindow(id: 8, frame: main, target: target(main, window: main)),
        ])
        #expect(frozen.lookup(CGPoint(x: 600, y: 600)) == .live)
        #expect(frozen.lookup(CGPoint(x: 2000, y: 2000)) == .live)
        #expect(mapped(frozen.lookup(CGPoint(x: 100, y: 100)))?.frame == main)
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
