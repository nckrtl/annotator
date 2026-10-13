import AnnotatorNativeCore
import AppKit
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case outsideDisplay
    case failed(String)

    var description: String {
        switch self {
        case .noDisplay: "No display contains the annotated area."
        case .outsideDisplay: "The annotated area is outside the display."
        case .failed(let message): message
        }
    }
}

enum Capture {
    static let margin: CGFloat = 24

    struct Result {
        var dataURL: String
        /// The display size in pixels, for `screenSize`.
        var screenSize: CGSize
    }

    /// Captures `rect` (global top-left points) plus a margin, from the display that holds its center.
    /// The helper's and Annotator's windows are excluded, so the overlay and panels are not in the image.
    static func capture(_ rect: CGRect) async throws -> Result {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed("Screen Recording is not available: \(error.localizedDescription)")
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
        else { throw CaptureError.noDisplay }
        let bounds = CGDisplayBounds(display.displayID)
        guard let source = Geometry.captureRect(for: rect, margin: margin, display: bounds)
        else { throw CaptureError.outsideDisplay }

        let filter = SCContentFilter(
            display: display, excludingApplications: content.applications.filter { ourPids.contains($0.processID) },
            exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        let pixels = Geometry.pixelSize(of: source, scale: CGFloat(filter.pointPixelScale))
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureError.failed("Screen capture failed: \(error.localizedDescription)")
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let screenSize = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
        return Result(dataURL: try ScreenshotEncoder.dataURL(for: image), screenSize: screenSize)
    }
}
