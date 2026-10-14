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
    /// The helper's windows are excluded, so the overlay is not in the image.
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

    /// One display as it looked when annotate mode started.
    struct Still {
        /// Global top-left points.
        var bounds: CGRect
        var image: CGImage
        /// The display size in pixels, for `screenSize`.
        var screenSize: CGSize
    }

    /// Every display, without the helper's overlay.
    static func stills() async throws -> [Still] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed("Screen Recording is not available: \(error.localizedDescription)")
        }
        let ours = content.applications.filter { ourPids.contains($0.processID) }
        var stills: [Still] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            let bounds = CGDisplayBounds(display.displayID)
            let configuration = SCStreamConfiguration()
            let pixels = Geometry.pixelSize(of: bounds, scale: CGFloat(filter.pointPixelScale))
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
            stills.append(Still(
                bounds: bounds, image: image,
                screenSize: CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)))
        }
        return stills
    }

    /// `rect` plus a margin, cut from the still of the display that holds its center.
    static func crop(_ rect: CGRect, from stills: [Still]) throws -> Result {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let still = stills.first(where: { $0.bounds.contains(center) }) else { throw CaptureError.noDisplay }
        let scale = CGFloat(still.image.width) / still.bounds.width
        guard let source = Geometry.captureRect(for: rect, margin: margin, display: still.bounds),
            let pixels = Geometry.pixelRect(
                of: source, scale: scale, imageSize: CGSize(width: still.image.width, height: still.image.height)),
            let image = still.image.cropping(to: pixels)
        else { throw CaptureError.outsideDisplay }
        return Result(dataURL: try ScreenshotEncoder.dataURL(for: image), screenSize: still.screenSize)
    }
}
