import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AnnotatorCore

/// Random pixels compress badly, so the JPEG stays large.
func noiseImage(width: Int, height: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt32 = 42
    for i in bytes.indices {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    let context = CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context.makeImage()!
}

struct ScreenshotEncoderTests {
    @Test func smallImageKeepsItsSize() throws {
        let url = try ScreenshotEncoder.dataURL(for: noiseImage(width: 40, height: 30))
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
        let data = try #require(Data(base64Encoded: String(url.dropFirst(ScreenshotEncoder.prefix.count))))
        let image = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        #expect(image.width == 40 && image.height == 30)
    }

    @Test func largeImageIsDownscaledUnderTheLimit() throws {
        let limit = 200_000
        let image = noiseImage(width: 1200, height: 900)
        let url = try ScreenshotEncoder.dataURL(for: image, maxBytes: limit)
        #expect(url.utf8.count <= limit)
        let data = try #require(Data(base64Encoded: String(url.dropFirst(ScreenshotEncoder.prefix.count))))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        #expect(decoded.width < 1200)
    }

    @Test func impossibleLimitFailsLoudly() {
        #expect(throws: ScreenshotError.tooLarge) {
            try ScreenshotEncoder.dataURL(for: noiseImage(width: 400, height: 400), maxBytes: 10)
        }
    }

    @Test func defaultLimitLeavesRoomForTheRecord() {
        #expect(ScreenshotEncoder.requestLimit - ScreenshotEncoder.recordReserve < 10 * 1024 * 1024)
    }
}
