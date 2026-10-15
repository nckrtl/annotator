import CoreGraphics
import Testing
@testable import AnnotatorNativeCore

struct WindowRulesTests {
    @Test func screenshotCanvasDoesNotBlockMappedAppElements() {
        let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                        CGRect(x: -3008, y: -575, width: 3008, height: 1692)]
        for display in displays {
            #expect(WindowRules.isScreenshotCanvas(bundleID: "com.apple.screencaptureui", frame: display, displays: displays))
            #expect(!WindowRules.isScreenshotCanvas(bundleID: "com.apple.TextEdit", frame: display, displays: displays))
        }
        // A canvas left at the previous, larger resolution still covers the built-in display.
        #expect(WindowRules.isScreenshotCanvas(bundleID: "com.apple.screencaptureui",
            frame: CGRect(x: 0, y: 0, width: 3008, height: 1692), displays: [displays[0]]))
    }

    @Test func screenshotToolbarAndPreviewStaySelectable() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        for frame in [CGRect(x: 500, y: 1000, width: 600, height: 70),
                      CGRect(x: 1400, y: 900, width: 300, height: 180),
                      CGRect(x: 0, y: 0, width: 1728, height: 39)] {
            #expect(!WindowRules.isScreenshotCanvas(bundleID: "com.apple.screencaptureui", frame: frame, displays: [display]))
        }
    }
}
