import CoreGraphics
import Testing

@testable import AnnotatorNativeCore

// Layout used below. Main screen 1512×982 at AppKit (0, 0).
// AppKit y grows up from the main screen's bottom; top-left y grows down from its top.
struct GeometryTests {
    let mainHeight: CGFloat = 982

    @Test func pointOnMainScreen() {
        let p = Geometry.topLeft(fromAppKit: CGPoint(x: 100, y: 900), mainScreenHeight: mainHeight)
        #expect(p == CGPoint(x: 100, y: 82))
    }

    @Test func rectOnMainScreen() {
        // A 180×22 box whose bottom edge is 600pt above the main screen's bottom.
        let r = Geometry.topLeft(fromAppKit: CGRect(x: 120, y: 600, width: 180, height: 22), mainScreenHeight: mainHeight)
        #expect(r == CGRect(x: 120, y: 360, width: 180, height: 22))
    }

    @Test func screenLeftOfMain() {
        // A 1920×1080 screen to the left, bottoms aligned: AppKit frame (-1920, 0).
        let screen = Geometry.topLeft(fromAppKit: CGRect(x: -1920, y: 0, width: 1920, height: 1080), mainScreenHeight: mainHeight)
        #expect(screen == CGRect(x: -1920, y: -98, width: 1920, height: 1080))
    }

    @Test func screenAboveMain() {
        // A 2560×1440 screen above the main one: AppKit frame (0, 982).
        let screen = Geometry.topLeft(fromAppKit: CGRect(x: 0, y: 982, width: 2560, height: 1440), mainScreenHeight: mainHeight)
        #expect(screen == CGRect(x: 0, y: -1440, width: 2560, height: 1440))
        // Its top-left corner in AppKit is (0, 2422).
        #expect(Geometry.topLeft(fromAppKit: CGPoint(x: 0, y: 2422), mainScreenHeight: mainHeight) == CGPoint(x: 0, y: -1440))
    }

    @Test func roundTrip() {
        let rect = CGRect(x: -500, y: -1200, width: 300, height: 40)
        let appKit = Geometry.appKit(fromTopLeft: rect, mainScreenHeight: mainHeight)
        #expect(Geometry.topLeft(fromAppKit: appKit, mainScreenHeight: mainHeight) == rect)
    }

    @Test func displayChangesKeepHitTestsInPoints() {
        // External XDR, built-in Retina and a 1x VM mode. Menu bars/notches do not
        // change the full display height used for the global coordinate conversion.
        for (height, scale) in [(1692.0, 2.0), (1117.0, 2.0), (768.0, 1.0)] {
            for origin in [CGPoint.zero, CGPoint(x: -1920, y: -200), CGPoint(x: 0, y: height)] {
                let frame = CGRect(x: origin.x + 40, y: origin.y + 100, width: 180, height: 24)
                let point = CGPoint(x: frame.midX, y: frame.midY)
                let mapped = Geometry.topLeft(fromAppKit: frame, mainScreenHeight: height)
                #expect(mapped.contains(Geometry.topLeft(fromAppKit: point, mainScreenHeight: height)))
                #expect(Geometry.appKit(fromTopLeft: mapped, mainScreenHeight: height) == frame)
                let pixels = Geometry.pixelSize(of: mapped, scale: scale)
                let expectedWidth = frame.width * CGFloat(scale)
                #expect(pixels.width == expectedWidth)
            }
        }
    }

    @Test func captureRectAddsMarginAndClips() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let r = Geometry.captureRect(for: CGRect(x: 10, y: 100, width: 50, height: 20), margin: 24, display: display)
        #expect(r == CGRect(x: 0, y: 76, width: 84, height: 68))
    }

    @Test func captureRectIsRelativeToSecondDisplay() {
        let display = CGRect(x: -1920, y: -98, width: 1920, height: 1080)
        let r = Geometry.captureRect(for: CGRect(x: -1000, y: 0, width: 100, height: 100), margin: 24, display: display)
        #expect(r == CGRect(x: 896, y: 74, width: 148, height: 148))
    }

    @Test func captureRectOutsideDisplay() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Geometry.captureRect(for: CGRect(x: 500, y: 500, width: 10, height: 10), margin: 24, display: display) == nil)
    }

    @Test func retinaPixelSize() {
        #expect(Geometry.pixelSize(of: CGRect(x: 0, y: 0, width: 84, height: 68.5), scale: 2) == CGSize(width: 168, height: 137))
        #expect(Geometry.pixelSize(of: CGRect(x: 0, y: 0, width: 84, height: 68), scale: 1) == CGSize(width: 84, height: 68))
    }

    @Test func usableFrames() {
        #expect(Geometry.isUsable(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(!Geometry.isUsable(CGRect(x: 0, y: 0, width: 0, height: 10)))
        #expect(!Geometry.isUsable(nil))
    }
}
